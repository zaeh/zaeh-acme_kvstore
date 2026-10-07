# @summary A secret value, as a plain String (e.g. already protected by hiera-eyaml) or wrapped in Sensitive for redaction.
type Acme_kvstore::Secret = Variant[String[1], Sensitive[String[1]]]
