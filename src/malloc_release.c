#include <caml/mlvalues.h>

#ifdef __APPLE__
#include <malloc/malloc.h>
#endif

CAMLprim value caml_malloc_release(value unit)
{
#ifdef __APPLE__
  malloc_zone_pressure_relief(NULL, 0);
#elif defined(__GLIBC__)
  /* malloc_trim is glibc-specific (not available in musl) */
  extern int malloc_trim(size_t);
  malloc_trim(0);
#endif
  return Val_unit;
}
