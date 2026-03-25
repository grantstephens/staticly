# vcl_recv - Request handling for static site
#
# - Strips query strings (static sites don't use them)
# - Redirects extensionless paths to add a trailing slash
# - Appends index.html to directory paths

# Strip query strings — they waste cache space on static content
set req.url = req.url.path;

# If the path has no file extension and doesn't end in /, redirect to add /
if (req.url.path !~ "\.\w+$" && req.url.path !~ "/$") {
  set req.http.x-redir = req.url.path "/";
  error 618 "redirect";
}

# Append index.html to directory paths
if (req.url.path ~ "/$") {
  set req.url = req.url.path "index.html";
}
