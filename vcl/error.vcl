# vcl_error - Custom error responses
#
# Handles:
# - 618: Trailing-slash redirect (from vcl_recv)
# - 904: Friendly 404 page (from vcl_fetch)

# Trailing-slash redirect issued from vcl_recv
if (obj.status == 618) {
  set obj.status = 301;
  set obj.http.Location = req.http.x-redir;
  set obj.response = "Moved Permanently";
  synthetic "";
  return(deliver);
}

# Friendly 404 page for missing files
if (obj.status == 904) {
  set obj.status = 404;
  set obj.response = "Not Found";
  set obj.http.Content-Type = "text/html; charset=utf-8";
  synthetic {"<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>404 - Not Found</title>
<style>
body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;display:flex;justify-content:center;align-items:center;min-height:100vh;margin:0;background:#fafafa;color:#1a1a1a}
.box{text-align:center}
h1{font-size:4rem;margin:0;color:#e23e3e}
p{color:#64748b;margin-top:.5rem}
a{color:#b4322a}
</style>
</head>
<body>
<div class="box">
<h1>404</h1>
<p>Page not found. <a href="/">Go home</a></p>
</div>
</body>
</html>"};
  return(deliver);
}
