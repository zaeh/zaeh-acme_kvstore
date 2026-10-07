# @summary Size of the RFC 7919 ffdhe group used for DH parameters (see acme_kvstore::deploy).
type Acme_kvstore::Dh_param_size = Variant[Integer[2048, 2048], Integer[3072, 3072], Integer[4096, 4096]]
