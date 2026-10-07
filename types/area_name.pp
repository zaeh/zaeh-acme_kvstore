# @summary The name of an area, as CCI-UI accepts it: [a-z][a-z0-9_]{0,47}.
type Acme_kvstore::Area_name = Pattern[/\A[a-z][a-z0-9_]{0,47}\z/]
