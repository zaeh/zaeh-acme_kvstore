# @summary Returns the plain value of a Sensitive[String], or the value unchanged if it is not Sensitive.
#
# Secrets may be given plain or as Sensitive; the Ruby code needs the plain
# value.
#
# @api private
# @param value A plain value, a Sensitive[String] or undef.
# @return The plain value (undef stays undef).
function acme_kvstore::unwrap_if_sensitive(
  Optional[Variant[Acme_kvstore::Secret, Integer]] $value
) >> Optional[Variant[String[1], Integer]] {
  if $value =~ Sensitive {
    $value.unwrap
  } else {
    $value
  }
}
