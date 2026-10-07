# @summary One entry of $acme_kvstore::dnsapi_scripts: a custom acme.sh DNS API script.
#
# Exactly one of source (puppet:/// URL or absolute path) or content. The
# script defines <hook>_add/<hook>_rm; DNS profiles use it via their hook.
# See docs/profiles.md.
type Acme_kvstore::Dnsapi_script = Variant[
  Struct[{ source => Stdlib::Filesource }],
  Struct[{ content => String[1] }],
]
