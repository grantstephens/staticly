# vcl_deliver - Set cache control headers
#
# Tell browsers to cache static assets aggressively but revalidate HTML.

if (resp.status == 200) {
  if (resp.http.Content-Type ~ "text/html") {
    # HTML: cache but revalidate on every request
    set resp.http.Cache-Control = "public, max-age=0, must-revalidate";
  } else {
    # Static assets (CSS, JS, images, fonts): cache for 1 year
    set resp.http.Cache-Control = "public, max-age=31536000, immutable";
  }
}
