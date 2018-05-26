#define PERL_NO_GET_CONTEXT      /* we want efficiency */
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "ppport.h"

/*
 * Duktape is an embeddable Javascript engine, with a focus on portability and
 * compact footprint.
 *
 * http://duktape.org/index.html
 */
#include "pl_duk.h"
#include "pl_stats.h"
#include "pl_eventloop.h"
#include "pl_console.h"

#define DUK_GC_RUNS                    2

/*
 * Native print callable from JS
 */
static duk_ret_t native_print(duk_context* ctx)
{
    duk_push_lstring(ctx, " ", 1);
    duk_insert(ctx, 0);
    duk_join(ctx, duk_get_top(ctx) - 1);
    PerlIO_stdoutf("%s\n", duk_safe_to_string(ctx, -1));
    return 0; // no return value
}

/*
 * Get JS compatible 'now' timestamp (millisecs since 1970).
 */
static duk_ret_t native_now_ms(duk_context* ctx)
{
    duk_push_number(ctx, (duk_double_t) (now_us() / 1000.0));
    return 1; //  return value at top
}

static int set_global_or_property(pTHX_ duk_context* ctx, const char* name, SV* value)
{
    if (sv_isobject(value)) {
        SV* obj = newSVsv(value);
        duk_push_pointer(ctx, obj);
    } else if (!pl_perl_to_duk(aTHX_ value, ctx)) {
        return 0;
    }
    int last_dot = -1;
    int len = 0;
    for (; name[len] != '\0'; ++len) {
        if (name[len] == '.') {
            last_dot = len;
        }
    }
    if (last_dot < 0) {
        if (!duk_put_global_lstring(ctx, name, len)) {
            croak("Could not save duk value for %s\n", name);
        }
    } else {
        duk_push_lstring(ctx, name + last_dot + 1, len - last_dot - 1);
        if (duk_peval_lstring(ctx, name, last_dot) != 0) {
            croak("Could not eval JS object %*.*s: %s\n",
                  last_dot, last_dot, name, duk_safe_to_string(ctx, -1));
        }
#if 0
        duk_enum(ctx, -1, 0);
        while (duk_next(ctx, -1, 0)) {
            fprintf(stderr, "KEY [%s]\n", duk_get_string(ctx, -1));
            duk_pop(ctx);  /* pop_key */
        }
#endif
         // Have [value, key, object], need [object, key, value], hence swap
        duk_swap(ctx, -3, -1);
        duk_put_prop(ctx, -3);
        duk_pop(ctx); // pop object
    }
    return 1;
}

static int session_dtor(pTHX_ SV* sv, MAGIC* mg)
{
    UNUSED_ARG(sv);
    Duk* duk = (Duk*) mg->mg_ptr;
    duk_destroy_heap(duk->ctx);
    return 0;
}

static void duk_fatal_error_handler(void* data, const char* msg)
{
    UNUSED_ARG(data);
    dTHX;
    PerlIO_printf(PerlIO_stderr(), "duktape fatal error, aborting: %s\n", msg ? msg : "*NONE*");
    abort();
}

static int register_native_functions(Duk* duk)
{
    static struct Data {
        const char* name;
        duk_c_function func;
    } data[] = {
        { "print"       , native_print  },
        { "timestamp_ms", native_now_ms },
    };
    duk_context* ctx = duk->ctx;
    int n = sizeof(data) / sizeof(data[0]);
    int j = 0;
    for (j = 0; j < n; ++j) {
        duk_push_c_function(ctx, data[j].func, DUK_VARARGS);
        if (!duk_put_global_string(ctx, data[j].name)) {
            croak("Could not register native function %s\n", data[j].name);
        }
    }
    return n;
}

static Duk* create_duktape_object(pTHX_ HV* opt)
{
    Duk* duk = (Duk*) malloc(sizeof(Duk));
    memset(duk, 0, sizeof(Duk));

    duk->pagesize = getpagesize();
    duk->stats = newHV();
    duk->msgs = newHV();

    duk->ctx = duk_create_heap(0, 0, 0, 0, duk_fatal_error_handler);
    if (!duk->ctx) {
        croak("Could not create duk heap\n");
    }

    if (opt) {
        hv_iterinit(opt);
        while (1) {
            SV* value = 0;
            I32 klen = 0;
            char* kstr = 0;
            HE* entry = hv_iternext(opt);
            if (!entry) {
                break; // no more hash keys
            }
            kstr = hv_iterkey(entry, &klen);
            if (!kstr || klen < 0) {
                continue; // invalid key
            }
            value = hv_iterval(opt, entry);
            if (!value) {
                continue; // invalid value
            }
            if (memcmp(kstr, DUK_OPT_NAME_GATHER_STATS, klen) == 0) {
                duk->flags |= SvTRUE(value) ? DUK_OPT_FLAG_GATHER_STATS : 0;
                continue;
            }
            if (memcmp(kstr, DUK_OPT_NAME_SAVE_MESSAGES, klen) == 0) {
                duk->flags |= SvTRUE(value) ? DUK_OPT_FLAG_SAVE_MESSAGES : 0;
                continue;
            }
            croak("Unknown option %*.*s\n", (int) klen, (int) klen, kstr);
        }
    }

    // register a bunch of native  functions
    register_native_functions(duk);

    // register event loop dispatcher
    pl_register_eventloop(duk);

    // initialize console object
    pl_console_init(duk);

    return duk;
}

static MGVTBL session_magic_vtbl = { .svt_free = session_dtor };

MODULE = JavaScript::Duktape::XS       PACKAGE = JavaScript::Duktape::XS
PROTOTYPES: DISABLE

#################################################################

Duk*
new(char* CLASS, HV* opt = NULL)
  CODE:
    UNUSED_ARG(opt);
    RETVAL = create_duktape_object(aTHX_ opt);
  OUTPUT: RETVAL

HV*
get_stats(Duk* duk)
  CODE:
    RETVAL = duk->stats;
  OUTPUT: RETVAL

void
reset_stats(Duk* duk)
  PPCODE:
    duk->stats = newHV();

HV*
get_msgs(Duk* duk)
  CODE:
    RETVAL = duk->msgs;
  OUTPUT: RETVAL

void
reset_msgs(Duk* duk)
  PPCODE:
    duk->msgs = newHV();

SV*
get(Duk* duk, const char* name)
  PREINIT:
    duk_context* ctx = 0;
    Stats stats;
  CODE:
    ctx = duk->ctx;
    RETVAL = &PL_sv_undef; // return undef by default
    pl_stats_start(aTHX_ duk, &stats);
    if (duk_get_global_string(ctx, name)) {
        RETVAL = pl_duk_to_perl(aTHX_ ctx, -1);
        duk_pop(ctx);
    }
    pl_stats_stop(aTHX_ duk, &stats, "get");
  OUTPUT: RETVAL

SV*
exists(Duk* duk, const char* name)
  PREINIT:
    duk_context* ctx = 0;
    Stats stats;
  CODE:
    ctx = duk->ctx;
    RETVAL = &PL_sv_no; // return false by default
    pl_stats_start(aTHX_ duk, &stats);
    if (duk_get_global_string(ctx, name)) {
        RETVAL = &PL_sv_yes;
        duk_pop(ctx);
    }
    pl_stats_stop(aTHX_ duk, &stats, "exists");
  OUTPUT: RETVAL

int
set(Duk* duk, const char* name, SV* value)
  PREINIT:
    duk_context* ctx = 0;
    Stats stats;
  CODE:
    ctx = duk->ctx;
    pl_stats_start(aTHX_ duk, &stats);
    RETVAL = set_global_or_property(aTHX_ ctx, name, value);
    pl_stats_stop(aTHX_ duk, &stats, "set");
  OUTPUT: RETVAL

SV*
eval(Duk* duk, const char* js, const char* file = 0)
  PREINIT:
    duk_context* ctx = 0;
    Stats stats;
    duk_uint_t flags = 0;
    duk_int_t rc = 0;
  CODE:
    ctx = duk->ctx;

    /* flags |= DUK_COMPILE_STRICT; */

    pl_stats_start(aTHX_ duk, &stats);
    if (!file) {
        rc = duk_pcompile_string(ctx, flags, js);
    }
    else {
        duk_push_string(ctx, file);
        rc = duk_pcompile_string_filename(ctx, flags, js);
    }
    pl_stats_stop(aTHX_ duk, &stats, "compile");

    if (rc != DUK_EXEC_SUCCESS) {
        croak("JS could not compile code: %s\n", duk_safe_to_string(ctx, -1));
    }

    pl_stats_start(aTHX_ duk, &stats);
    rc = duk_pcall(ctx, 0);
    pl_stats_stop(aTHX_ duk, &stats, "run");
    check_duktape_call_for_errors(rc, ctx);

    RETVAL = pl_duk_to_perl(aTHX_ ctx, -1);
    duk_pop(ctx);
  OUTPUT: RETVAL

SV*
dispatch_function_in_event_loop(Duk* duk, const char* func)
  PREINIT:
    Stats stats;
  CODE:
    pl_stats_start(aTHX_ duk, &stats);
    RETVAL = newSViv(pl_run_function_in_event_loop(duk, func));
    pl_stats_stop(aTHX_ duk, &stats, "dispatch");
  OUTPUT: RETVAL

SV*
run_gc(Duk* duk)
  PREINIT:
    duk_context* ctx = 0;
    Stats stats;
  CODE:
    ctx = duk->ctx;
    pl_stats_start(aTHX_ duk, &stats);
    for (int j = 0; j < DUK_GC_RUNS; ++j) {
        duk_gc(ctx, DUK_GC_COMPACT);
    }
    pl_stats_stop(aTHX_ duk, &stats, "run_gc");
    RETVAL = newSVnv(DUK_GC_RUNS);
  OUTPUT: RETVAL
