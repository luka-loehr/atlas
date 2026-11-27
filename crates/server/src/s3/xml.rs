//! S3 XML serialization and parsing helpers (strict XML entity escaping,
//! `DeleteObjects` and `CompleteMultipartUpload` XML parsing via `roxmltree`).

use atlas_common::models::{BucketInfo, ListObjectsResponse, PutObjectResponse};
use axum::http::{HeaderValue, StatusCode, header};
use axum::response::{IntoResponse, Response};
use chrono::{DateTime, SecondsFormat, Utc};

use crate::ApiError;
use crate::storage::multipart::{MultipartPartInfo, MultipartUploadInfo};

pub const S3_NS: &str = "http://s3.amazonaws.com/doc/2006-03-01/";

pub fn xml_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 8);
    for ch in s.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            c if c.is_control() && c != '\n' && c != '\r' && c != '\t' => {}
            c => out.push(c),
        }
    }
    out
}

fn iso_millis(dt: DateTime<Utc>) -> String {
    dt.to_rfc3339_opts(SecondsFormat::Millis, true)
}

pub fn xml_response(status: StatusCode, body: String, request_id: &str) -> Response {
    let mut resp = (status, body).into_response();
    resp.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("application/xml; charset=utf-8"),
    );
    if let Ok(v) = HeaderValue::from_str(request_id) {
        resp.headers_mut().insert("x-amz-request-id", v);
    }
    resp
}

pub fn s3_error_response(
    status: StatusCode,
    code: &str,
    message: &str,
    resource: &str,
    request_id: &str,
) -> Response {
    let xml = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\
         <Error>\
           <Code>{}</Code>\
           <Message>{}</Message>\
           <Resource>{}</Resource>\
           <RequestId>{}</RequestId>\
         </Error>",
        xml_escape(code),
        xml_escape(message),
        xml_escape(resource),
        xml_escape(request_id),
    );
    xml_response(status, xml, request_id)
}

pub fn api_error_to_s3(
    err: ApiError,
    resource: &str,
    request_id: &str,
    bucket_level: bool,
) -> Response {
    match err {
        ApiError::NotFound => {
            let code = if bucket_level {
                "NoSuchBucket"
            } else {
                "NoSuchKey"
            };
            s3_error_response(
                StatusCode::NOT_FOUND,
                code,
                "The specified resource does not exist.",
                resource,
                request_id,
            )
        }
        ApiError::BadRequest(m) => s3_error_response(
            StatusCode::BAD_REQUEST,
            "InvalidArgument",
            m,
            resource,
            request_id,
        ),
        ApiError::Unauthorized => s3_error_response(
            StatusCode::FORBIDDEN,
            "AccessDenied",
            "Authentication failed or signature mismatch.",
            resource,
            request_id,
        ),
        ApiError::Forbidden(m) => s3_error_response(
            StatusCode::FORBIDDEN,
            "AccessDenied",
            m,
            resource,
            request_id,
        ),
        ApiError::Conflict(m) => {
            let code = if m.contains("empty") {
                "BucketNotEmpty"
            } else {
                "OperationAborted"
            };
            s3_error_response(StatusCode::CONFLICT, code, m, resource, request_id)
        }
        ApiError::RateLimited { retry_after, limit } => {
            let mut resp = s3_error_response(
                StatusCode::TOO_MANY_REQUESTS,
                "SlowDown",
                "Please reduce your request rate.",
                resource,
                request_id,
            );
            if let Ok(v) = HeaderValue::from_str(&retry_after.max(1).to_string()) {
                resp.headers_mut().insert(header::RETRY_AFTER, v);
            }
            if let Ok(v) = HeaderValue::from_str(&limit.to_string()) {
                resp.headers_mut().insert("x-ratelimit-limit", v);
            }
            resp
        }
        ApiError::TooLarge => s3_error_response(
            StatusCode::BAD_REQUEST,
            "EntityTooLarge",
            "Your proposed upload exceeds the maximum allowed object size or quota.",
            resource,
            request_id,
        ),
        ApiError::Unavailable(m) => s3_error_response(
            StatusCode::SERVICE_UNAVAILABLE,
            "ServiceUnavailable",
            m,
            resource,
            request_id,
        ),
        ApiError::Internal(e) => {
            tracing::error!("s3 internal error: {e:#}");
            s3_error_response(
                StatusCode::INTERNAL_SERVER_ERROR,
                "InternalError",
                "We encountered an internal error.",
                resource,
                request_id,
            )
        }
    }
}

pub fn render_list_buckets(buckets: &[BucketInfo], owner_id: &str) -> String {
    let mut xml = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\
         <ListAllMyBucketsResult xmlns=\"{S3_NS}\">\
           <Owner><ID>{}</ID><DisplayName>{}</DisplayName></Owner>\
           <Buckets>",
        xml_escape(owner_id),
        xml_escape(owner_id),
    );
    for b in buckets {
        xml.push_str(&format!(
            "<Bucket><Name>{}</Name><CreationDate>{}</CreationDate></Bucket>",
            xml_escape(&b.name),
            iso_millis(b.created_at),
        ));
    }
    xml.push_str("</Buckets></ListAllMyBucketsResult>");
    xml
}

pub fn render_list_objects_v2(
    res: &ListObjectsResponse,
    max_keys: usize,
    continuation_token: Option<&str>,
    start_after: Option<&str>,
) -> String {
    let key_count = res.objects.len() + res.common_prefixes.len();
    let mut xml = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\
         <ListBucketResult xmlns=\"{S3_NS}\">\
           <Name>{}</Name>\
           <Prefix>{}</Prefix>\
           <KeyCount>{}</KeyCount>\
           <MaxKeys>{}</MaxKeys>\
           <IsTruncated>{}</IsTruncated>",
        xml_escape(&res.bucket),
        xml_escape(&res.prefix),
        key_count,
        max_keys,
        res.is_truncated,
    );
    if let Some(ref d) = res.delimiter {
        xml.push_str(&format!("<Delimiter>{}</Delimiter>", xml_escape(d)));
    }
    if let Some(ct) = continuation_token {
        xml.push_str(&format!(
            "<ContinuationToken>{}</ContinuationToken>",
            xml_escape(ct)
        ));
    }
    if let Some(sa) = start_after {
        xml.push_str(&format!("<StartAfter>{}</StartAfter>", xml_escape(sa)));
    }
    if let Some(ref next) = res.next_cursor {
        xml.push_str(&format!(
            "<NextContinuationToken>{}</NextContinuationToken>",
            xml_escape(next)
        ));
    }
    for obj in &res.objects {
        xml.push_str(&format!(
            "<Contents>\
               <Key>{}</Key>\
               <LastModified>{}</LastModified>\
               <ETag>{}</ETag>\
               <Size>{}</Size>\
               <StorageClass>STANDARD</StorageClass>\
             </Contents>",
            xml_escape(&obj.key),
            iso_millis(obj.updated_at),
            xml_escape(&obj.etag),
            obj.size,
        ));
    }
    for cp in &res.common_prefixes {
        xml.push_str(&format!(
            "<CommonPrefixes><Prefix>{}</Prefix></CommonPrefixes>",
            xml_escape(cp)
        ));
    }
    xml.push_str("</ListBucketResult>");
    xml
}

pub fn render_list_objects_v1(
    res: &ListObjectsResponse,
    max_keys: usize,
    marker: Option<&str>,
) -> String {
    let mut xml = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\
         <ListBucketResult xmlns=\"{S3_NS}\">\
           <Name>{}</Name>\
           <Prefix>{}</Prefix>\
           <Marker>{}</Marker>\
           <MaxKeys>{}</MaxKeys>\
           <IsTruncated>{}</IsTruncated>",
        xml_escape(&res.bucket),
        xml_escape(&res.prefix),
        xml_escape(marker.unwrap_or("")),
        max_keys,
        res.is_truncated,
    );
    if let Some(ref d) = res.delimiter {
        xml.push_str(&format!("<Delimiter>{}</Delimiter>", xml_escape(d)));
    }
    if let Some(ref next) = res.next_cursor {
        xml.push_str(&format!("<NextMarker>{}</NextMarker>", xml_escape(next)));
    }
    for obj in &res.objects {
        xml.push_str(&format!(
            "<Contents>\
               <Key>{}</Key>\
               <LastModified>{}</LastModified>\
               <ETag>{}</ETag>\
               <Size>{}</Size>\
               <StorageClass>STANDARD</StorageClass>\
             </Contents>",
            xml_escape(&obj.key),
            iso_millis(obj.updated_at),
            xml_escape(&obj.etag),
            obj.size,
        ));
    }
    for cp in &res.common_prefixes {
        xml.push_str(&format!(
            "<CommonPrefixes><Prefix>{}</Prefix></CommonPrefixes>",
            xml_escape(cp)
        ));
    }
    xml.push_str("</ListBucketResult>");
    xml
}

pub fn render_copy_result(res: &PutObjectResponse) -> String {
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\
         <CopyObjectResult xmlns=\"{S3_NS}\">\
           <LastModified>{}</LastModified>\
           <ETag>{}</ETag>\
         </CopyObjectResult>",
        iso_millis(Utc::now()),
        xml_escape(&res.etag),
    )
}

pub fn render_initiate_multipart(up: &MultipartUploadInfo) -> String {
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\
         <InitiateMultipartUploadResult xmlns=\"{S3_NS}\">\
           <Bucket>{}</Bucket>\
           <Key>{}</Key>\
           <UploadId>{}</UploadId>\
         </InitiateMultipartUploadResult>",
        xml_escape(&up.bucket),
        xml_escape(&up.key),
        xml_escape(&up.upload_id),
    )
}

pub fn render_complete_multipart(res: &PutObjectResponse, location: &str) -> String {
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\
         <CompleteMultipartUploadResult xmlns=\"{S3_NS}\">\
           <Location>{}</Location>\
           <Bucket>{}</Bucket>\
           <Key>{}</Key>\
           <ETag>{}</ETag>\
         </CompleteMultipartUploadResult>",
        xml_escape(location),
        xml_escape(&res.bucket),
        xml_escape(&res.key),
        xml_escape(&res.etag),
    )
}

pub fn render_list_multipart_uploads(bucket: &str, uploads: &[MultipartUploadInfo]) -> String {
    let mut xml = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\
         <ListMultipartUploadsResult xmlns=\"{S3_NS}\">\
           <Bucket>{}</Bucket>\
           <IsTruncated>false</IsTruncated>",
        xml_escape(bucket),
    );
    for u in uploads {
        xml.push_str(&format!(
            "<Upload><Key>{}</Key><UploadId>{}</UploadId><Initiated>{}</Initiated></Upload>",
            xml_escape(&u.key),
            xml_escape(&u.upload_id),
            iso_millis(u.created_at),
        ));
    }
    xml.push_str("</ListMultipartUploadsResult>");
    xml
}

pub fn render_list_parts(
    bucket: &str,
    key: &str,
    upload_id: &str,
    parts: &[MultipartPartInfo],
) -> String {
    let mut xml = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\
         <ListPartsResult xmlns=\"{S3_NS}\">\
           <Bucket>{}</Bucket>\
           <Key>{}</Key>\
           <UploadId>{}</UploadId>\
           <IsTruncated>false</IsTruncated>",
        xml_escape(bucket),
        xml_escape(key),
        xml_escape(upload_id),
    );
    for p in parts {
        xml.push_str(&format!(
            "<Part>\
               <PartNumber>{}</PartNumber>\
               <LastModified>{}</LastModified>\
               <ETag>{}</ETag>\
               <Size>{}</Size>\
             </Part>",
            p.part_number,
            iso_millis(p.created_at),
            xml_escape(&p.etag),
            p.size,
        ));
    }
    xml.push_str("</ListPartsResult>");
    xml
}

pub fn render_delete_result(deleted: &[String], quiet: bool) -> String {
    let mut xml = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\
         <DeleteResult xmlns=\"{S3_NS}\">"
    );
    if !quiet {
        for k in deleted {
            xml.push_str(&format!("<Deleted><Key>{}</Key></Deleted>", xml_escape(k)));
        }
    }
    xml.push_str("</DeleteResult>");
    xml
}

/// Parses S3 `<Delete><Quiet>...</Quiet><Object><Key>...</Key></Object></Delete>` XML.
pub fn parse_delete_objects_xml(xml_str: &str) -> Result<(Vec<String>, bool), ApiError> {
    let doc = roxmltree::Document::parse(xml_str)
        .map_err(|_| ApiError::BadRequest("malformed Delete XML"))?;
    let mut keys = Vec::new();
    let mut quiet = false;
    for node in doc.descendants() {
        if node.has_tag_name("Quiet")
            && let Some(t) = node.text()
        {
            quiet = t.trim().eq_ignore_ascii_case("true");
        } else if node.has_tag_name("Object") {
            for child in node.children() {
                if child.has_tag_name("Key")
                    && let Some(k) = child.text()
                {
                    keys.push(k.to_string());
                }
            }
        }
    }
    Ok((keys, quiet))
}

/// Parses S3 `<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>...</ETag></Part></CompleteMultipartUpload>`.
pub fn parse_complete_multipart_xml(xml_str: &str) -> Result<Vec<(i32, String)>, ApiError> {
    let trimmed = xml_str.trim();
    if trimmed.is_empty() {
        return Ok(vec![]);
    }
    let doc = roxmltree::Document::parse(trimmed)
        .map_err(|_| ApiError::BadRequest("malformed CompleteMultipartUpload XML"))?;
    let mut parts = Vec::new();
    for node in doc.descendants() {
        if node.has_tag_name("Part") {
            let mut pn = None;
            let mut etag = String::new();
            for child in node.children() {
                if child.has_tag_name("PartNumber") {
                    pn = child.text().and_then(|t| t.trim().parse::<i32>().ok());
                } else if child.has_tag_name("ETag") {
                    etag = child.text().unwrap_or("").trim().to_string();
                }
            }
            let pn = pn.ok_or(ApiError::BadRequest("Part missing valid PartNumber"))?;
            parts.push((pn, etag));
        }
    }
    Ok(parts)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_delete_and_complete_xml_documents() {
        let del = r#"<Delete xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Quiet>false</Quiet><Object><Key>a/b.pdf</Key></Object><Object><Key>c.txt</Key></Object></Delete>"#;
        let (keys, quiet) = parse_delete_objects_xml(del).unwrap();
        assert!(!quiet);
        assert_eq!(keys, vec!["a/b.pdf", "c.txt"]);

        let cmp = r#"<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>"abc"</ETag></Part><Part><PartNumber>2</PartNumber><ETag>"def"</ETag></Part></CompleteMultipartUpload>"#;
        let parts = parse_complete_multipart_xml(cmp).unwrap();
        assert_eq!(parts, vec![(1, "\"abc\"".into()), (2, "\"def\"".into())]);
    }
}
