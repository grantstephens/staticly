# vcl_miss - Sign backend requests to Fastly Object Storage
#
# Generates an AWS V4 signature to authenticate requests to the private
# Object Storage bucket. Credentials are stored in a private (write-only)
# Edge Dictionary named "object_storage_config" with the following keys:
#   - access_key : Fastly Object Storage access key ID
#   - secret_key : Fastly Object Storage secret key
#   - bucket     : Name of the Object Storage bucket
#   - region     : Object Storage region (e.g. us-east)

declare local var.fosAccessKey STRING;
declare local var.fosSecretKey STRING;
declare local var.fosBucket STRING;
declare local var.fosRegion STRING;
declare local var.fosHost STRING;
declare local var.canonicalHeaders STRING;
declare local var.signedHeaders STRING;
declare local var.canonicalRequest STRING;
declare local var.canonicalQuery STRING;
declare local var.stringToSign STRING;
declare local var.dateStamp STRING;
declare local var.signature STRING;
declare local var.scope STRING;

# Read credentials from the private Edge Dictionary
set var.fosAccessKey = table.lookup(object_storage_config, "access_key");
set var.fosSecretKey = table.lookup(object_storage_config, "secret_key");
set var.fosBucket = table.lookup(object_storage_config, "bucket");
set var.fosRegion = table.lookup(object_storage_config, "region");

set var.fosHost = var.fosRegion ".object.fastlystorage.app";

if ((req.method == "GET" || req.method == "HEAD") && !req.backend.is_shield) {
  set bereq.http.x-amz-content-sha256 = digest.hash_sha256("");
  set bereq.http.x-amz-date = strftime({"%Y%m%dT%H%M%SZ"}, now);
  set bereq.http.host = var.fosHost;

  # Prepend the bucket name to the request path
  set bereq.url = "/" var.fosBucket bereq.url;
  set bereq.url = querystring.remove(bereq.url);
  set bereq.url = regsuball(urlencode(urldecode(bereq.url.path)), {"%2F"}, "/");

  set var.dateStamp = strftime({"%Y%m%d"}, now);
  set var.canonicalHeaders = ""
    "host:" bereq.http.host LF
    "x-amz-content-sha256:" bereq.http.x-amz-content-sha256 LF
    "x-amz-date:" bereq.http.x-amz-date LF
  ;
  set var.canonicalQuery = "";
  set var.signedHeaders = "host;x-amz-content-sha256;x-amz-date";
  set var.canonicalRequest = ""
    "GET" LF
    bereq.url.path LF
    var.canonicalQuery LF
    var.canonicalHeaders LF
    var.signedHeaders LF
    digest.hash_sha256("")
  ;

  set var.scope = var.dateStamp "/" var.fosRegion "/s3/aws4_request";

  set var.stringToSign = ""
    "AWS4-HMAC-SHA256" LF
    bereq.http.x-amz-date LF
    var.scope LF
    regsub(digest.hash_sha256(var.canonicalRequest), "^0x", "")
  ;

  set var.signature = digest.awsv4_hmac(
    var.fosSecretKey,
    var.dateStamp,
    var.fosRegion,
    "s3",
    var.stringToSign
  );

  set bereq.http.Authorization = "AWS4-HMAC-SHA256 "
    "Credential=" var.fosAccessKey "/" var.scope ", "
    "SignedHeaders=" var.signedHeaders ", "
    "Signature=" + regsub(var.signature, "^0x", "")
  ;

  # Remove headers not needed by the origin
  unset bereq.http.Accept;
  unset bereq.http.Accept-Language;
  unset bereq.http.User-Agent;
  unset bereq.http.Fastly-Client-IP;
}
