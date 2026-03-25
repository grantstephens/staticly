# vcl_fetch - Handle backend errors
#
# Object Storage returns 403 for missing keys. Trigger vcl_error to
# generate a friendly 404 page.

if (beresp.status == 403 || beresp.status == 404) {
  error 904 "Not Found";
}
