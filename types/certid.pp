# @summary A certificate ID: a single KV path segment (letters, digits, '.', '_' and '-'),
#   at most 120 characters as in CCI-UI.
type Acme_kvstore::Certid = Pattern[/\A[A-Za-z0-9_.-]{1,120}\z/]
