/* Platform-optimized directory listing that returns subdirectory names
   and file count without needing stat() calls.
   On Unix (macOS/Linux): uses d_type from readdir.
   On Windows: uses FindFirstFile with FILE_ATTRIBUTE_DIRECTORY. */

#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/fail.h>

#ifdef _WIN32

#include <windows.h>

CAMLprim value caml_readdir_types(value v_path)
{
  CAMLparam1(v_path);
  CAMLlocal3(result, list, cons);
  WIN32_FIND_DATAW ffd;
  HANDLE hFind;
  int nFiles = 0;
  char searchPath[MAX_PATH + 3];
  wchar_t wSearchPath[MAX_PATH + 3];

  snprintf(searchPath, sizeof(searchPath), "%s\\*", String_val(v_path));
  MultiByteToWideChar(CP_UTF8, 0, searchPath, -1, wSearchPath, MAX_PATH + 3);

  hFind = FindFirstFileW(wSearchPath, &ffd);
  if (hFind == INVALID_HANDLE_VALUE) {
    result = caml_alloc(2, 0);
    Store_field(result, 0, Val_emptylist);
    Store_field(result, 1, Val_int(0));
    CAMLreturn(result);
  }

  list = Val_emptylist;
  do {
    /* Skip . and .. */
    if (ffd.cFileName[0] == L'.' &&
        (ffd.cFileName[1] == L'\0' ||
         (ffd.cFileName[1] == L'.' && ffd.cFileName[2] == L'\0')))
      continue;

    if (ffd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
      char name[MAX_PATH * 3];
      WideCharToMultiByte(CP_UTF8, 0, ffd.cFileName, -1, name, sizeof(name),
                          NULL, NULL);
      cons = caml_alloc(2, 0);
      Store_field(cons, 0, caml_copy_string(name));
      Store_field(cons, 1, list);
      list = cons;
    } else {
      nFiles++;
    }
  } while (FindNextFileW(hFind, &ffd) != 0);
  FindClose(hFind);

  result = caml_alloc(2, 0);
  Store_field(result, 0, list);
  Store_field(result, 1, Val_int(nFiles));
  CAMLreturn(result);
}

#else /* Unix (macOS, Linux, etc.) */

#include <dirent.h>
#include <string.h>

CAMLprim value caml_readdir_types(value v_path)
{
  CAMLparam1(v_path);
  CAMLlocal3(result, list, cons);
  DIR *d;
  struct dirent *ent;
  int nFiles = 0;

  d = opendir(String_val(v_path));
  if (!d) {
    result = caml_alloc(2, 0);
    Store_field(result, 0, Val_emptylist);
    Store_field(result, 1, Val_int(0));
    CAMLreturn(result);
  }

  list = Val_emptylist;
  while ((ent = readdir(d)) != NULL) {
    /* Skip . and .. */
    if (ent->d_name[0] == '.' &&
        (ent->d_name[1] == '\0' ||
         (ent->d_name[1] == '.' && ent->d_name[2] == '\0')))
      continue;

    if (ent->d_type == DT_DIR) {
      cons = caml_alloc(2, 0);
      Store_field(cons, 0, caml_copy_string(ent->d_name));
      Store_field(cons, 1, list);
      list = cons;
    } else if (ent->d_type == DT_UNKNOWN) {
      /* Filesystem doesn't support d_type (e.g. some NFS).
         Fall back: try opendir to check if it's a directory. */
      char childPath[PATH_MAX];
      snprintf(childPath, sizeof(childPath), "%s/%s",
               String_val(v_path), ent->d_name);
      DIR *child = opendir(childPath);
      if (child) {
        closedir(child);
        cons = caml_alloc(2, 0);
        Store_field(cons, 0, caml_copy_string(ent->d_name));
        Store_field(cons, 1, list);
        list = cons;
      } else {
        nFiles++;
      }
    } else {
      nFiles++;
    }
  }
  closedir(d);

  result = caml_alloc(2, 0);
  Store_field(result, 0, list);
  Store_field(result, 1, Val_int(nFiles));
  CAMLreturn(result);
}

#endif
