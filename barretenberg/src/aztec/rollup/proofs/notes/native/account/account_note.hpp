#pragma once
#include <ecc/curves/grumpkin/grumpkin.hpp>
#include <crypto/pedersen/pedersen.hpp>
#include "../../constants.hpp"

namespace rollup {
namespace proofs {
namespace notes {
namespace native {
namespace account {

grumpkin::fq generate_account_commitment(const barretenberg::fr& account_alias_id,
                                         const barretenberg::fr& owner_x,
                                         const barretenberg::fr& signing_x);

struct account_note {
    barretenberg::fr account_alias_id;
    grumpkin::g1::affine_element owner_key;
    grumpkin::g1::affine_element signing_key;

    grumpkin::fq commit() const;
};

} // namespace account
} // namespace native
} // namespace notes
} // namespace proofs
} // namespace rollup