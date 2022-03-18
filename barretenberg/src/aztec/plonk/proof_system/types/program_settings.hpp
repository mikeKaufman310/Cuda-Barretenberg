#pragma once

#include <cstdint>

#include "../../transcript/transcript_wrappers.hpp"
#include "../widgets/transition_widgets/arithmetic_widget.hpp"
#include "../widgets/transition_widgets/turbo_arithmetic_widget.hpp"
#include "../widgets/transition_widgets/turbo_fixed_base_widget.hpp"
#include "../widgets/transition_widgets/turbo_logic_widget.hpp"
#include "../widgets/transition_widgets/turbo_range_widget.hpp"
#include "../widgets/transition_widgets/elliptic_widget.hpp"
#include "../widgets/random_widgets/random_widget.hpp"
#include "../widgets/random_widgets/permutation_widget.hpp"
#include "./prover_settings.hpp"

namespace waffle {

class standard_verifier_settings : public standard_settings {
  public:
    typedef barretenberg::fr fr;
    typedef barretenberg::g1 g1;
    typedef transcript::StandardTranscript Transcript;
    typedef VerifierArithmeticWidget<fr, g1::affine_element, Transcript, standard_settings> ArithmeticWidget;
    typedef VerifierPermutationWidget<fr, g1::affine_element, Transcript> PermutationWidget;

    static constexpr size_t num_challenge_bytes = 32;
    static constexpr transcript::HashType hash_type = transcript::HashType::Keccak256;
    static constexpr bool use_linearisation = true;
    static constexpr bool idpolys = false;

    static fr append_scalar_multiplication_inputs(verification_key* key,
                                                  const fr& alpha_base,
                                                  const Transcript& transcript,
                                                  std::map<std::string, fr>& scalars)
    {
        auto updated_alpha = PermutationWidget::append_scalar_multiplication_inputs(
            key, alpha_base, transcript, scalars, use_linearisation);

        return ArithmeticWidget::append_scalar_multiplication_inputs(key, updated_alpha, transcript, scalars);
    }

    static barretenberg::fr compute_quotient_evaluation_contribution(verification_key* key,
                                                                     const fr& alpha_base,
                                                                     const Transcript& transcript,
                                                                     fr& r_0)
    {
        auto updated_alpha_base = PermutationWidget::compute_quotient_evaluation_contribution(
            key, alpha_base, transcript, r_0, use_linearisation, false);
        updated_alpha_base =
            ArithmeticWidget::compute_quotient_evaluation_contribution(key, updated_alpha_base, transcript, r_0);
        return updated_alpha_base;
    }
};

class unrolled_standard_verifier_settings : public unrolled_standard_settings {
  public:
    typedef barretenberg::fr fr;
    typedef barretenberg::g1 g1;
    typedef transcript::StandardTranscript Transcript;
    typedef VerifierArithmeticWidget<fr, g1::affine_element, Transcript, unrolled_standard_settings> ArithmeticWidget;
    typedef VerifierPermutationWidget<fr, g1::affine_element, Transcript> PermutationWidget;

    static constexpr transcript::HashType hash_type = transcript::HashType::PedersenBlake2s;
    static constexpr size_t num_challenge_bytes = 16;
    static constexpr bool use_linearisation = false;
    static constexpr bool idpolys = false;

    static fr append_scalar_multiplication_inputs(verification_key* key,
                                                  const fr& alpha_base,
                                                  const Transcript& transcript,
                                                  std::map<std::string, fr>& scalars)
    {
        auto updated_alpha = PermutationWidget::append_scalar_multiplication_inputs(
            key, alpha_base, transcript, scalars, use_linearisation);

        return ArithmeticWidget::append_scalar_multiplication_inputs(key, updated_alpha, transcript, scalars);
    }

    static barretenberg::fr compute_quotient_evaluation_contribution(verification_key* key,
                                                                     const barretenberg::fr& alpha_base,
                                                                     const transcript::StandardTranscript& transcript,
                                                                     barretenberg::fr& r_0)
    {
        auto updated_alpha_base = VerifierPermutationWidget<barretenberg::fr,
                                                            barretenberg::g1::affine_element,
                                                            transcript::StandardTranscript>::
            compute_quotient_evaluation_contribution(key, alpha_base, transcript, r_0, use_linearisation);

        return ArithmeticWidget::compute_quotient_evaluation_contribution(key, updated_alpha_base, transcript, r_0);
    }
};

class turbo_verifier_settings : public turbo_settings {
  public:
    typedef barretenberg::fr fr;
    typedef barretenberg::g1 g1;
    typedef transcript::StandardTranscript Transcript;
    typedef VerifierTurboArithmeticWidget<fr, g1::affine_element, Transcript, turbo_settings> TurboArithmeticWidget;
    typedef VerifierTurboFixedBaseWidget<fr, g1::affine_element, Transcript, turbo_settings> TurboFixedBaseWidget;
    typedef VerifierTurboRangeWidget<fr, g1::affine_element, Transcript, turbo_settings> TurboRangeWidget;
    typedef VerifierTurboLogicWidget<fr, g1::affine_element, Transcript, turbo_settings> TurboLogicWidget;
    typedef VerifierPermutationWidget<fr, g1::affine_element, Transcript> PermutationWidget;

    static constexpr size_t num_challenge_bytes = 32;
    static constexpr transcript::HashType hash_type = transcript::HashType::Keccak256;
    static constexpr bool use_linearisation = true;
    static constexpr bool idpolys = false;

    static fr append_scalar_multiplication_inputs(verification_key* key,
                                                  const fr& alpha_base,
                                                  const transcript::StandardTranscript& transcript,
                                                  std::map<std::string, fr>& scalars)
    {
        auto updated_alpha = PermutationWidget::append_scalar_multiplication_inputs(
            key, alpha_base, transcript, scalars, use_linearisation);

        updated_alpha =
            TurboArithmeticWidget::append_scalar_multiplication_inputs(key, updated_alpha, transcript, scalars);
        updated_alpha =
            TurboFixedBaseWidget::append_scalar_multiplication_inputs(key, updated_alpha, transcript, scalars);
        updated_alpha = TurboRangeWidget::append_scalar_multiplication_inputs(key, updated_alpha, transcript, scalars);
        updated_alpha = TurboLogicWidget::append_scalar_multiplication_inputs(key, updated_alpha, transcript, scalars);

        return updated_alpha;
    }

    static barretenberg::fr compute_quotient_evaluation_contribution(verification_key* key,
                                                                     const fr& alpha_base,
                                                                     const Transcript& transcript,
                                                                     fr& r_0)
    {
        auto updated_alpha_base = PermutationWidget::compute_quotient_evaluation_contribution(
            key, alpha_base, transcript, r_0, use_linearisation, false);

        updated_alpha_base =
            TurboArithmeticWidget::compute_quotient_evaluation_contribution(key, updated_alpha_base, transcript, r_0);
        updated_alpha_base =
            TurboFixedBaseWidget::compute_quotient_evaluation_contribution(key, updated_alpha_base, transcript, r_0);
        updated_alpha_base =
            TurboRangeWidget::compute_quotient_evaluation_contribution(key, updated_alpha_base, transcript, r_0);
        updated_alpha_base =
            TurboLogicWidget::compute_quotient_evaluation_contribution(key, updated_alpha_base, transcript, r_0);

        return updated_alpha_base;
    }
};

class unrolled_turbo_verifier_settings : public unrolled_turbo_settings {
  public:
    typedef barretenberg::fr fr;
    typedef barretenberg::g1 g1;
    typedef transcript::StandardTranscript Transcript;
    typedef VerifierTurboArithmeticWidget<fr, g1::affine_element, Transcript, unrolled_turbo_settings>
        TurboArithmeticWidget;
    typedef VerifierTurboFixedBaseWidget<fr, g1::affine_element, Transcript, unrolled_turbo_settings>
        TurboFixedBaseWidget;
    typedef VerifierTurboRangeWidget<fr, g1::affine_element, Transcript, unrolled_turbo_settings> TurboRangeWidget;
    typedef VerifierTurboLogicWidget<fr, g1::affine_element, Transcript, unrolled_turbo_settings> TurboLogicWidget;
    typedef VerifierPermutationWidget<fr, g1::affine_element, Transcript> PermutationWidget;

    static constexpr size_t num_challenge_bytes = 16;
    static constexpr transcript::HashType hash_type = transcript::HashType::PedersenBlake2s;
    static constexpr bool use_linearisation = false;
    static constexpr bool idpolys = false;

    static fr append_scalar_multiplication_inputs(verification_key* key,
                                                  const fr& alpha_base,
                                                  const Transcript& transcript,
                                                  std::map<std::string, fr>& scalars)
    {
        auto updated_alpha = PermutationWidget::append_scalar_multiplication_inputs(
            key, alpha_base, transcript, scalars, use_linearisation);

        updated_alpha =
            TurboArithmeticWidget::append_scalar_multiplication_inputs(key, updated_alpha, transcript, scalars);
        updated_alpha =
            TurboFixedBaseWidget::append_scalar_multiplication_inputs(key, updated_alpha, transcript, scalars);
        updated_alpha = TurboRangeWidget::append_scalar_multiplication_inputs(key, updated_alpha, transcript, scalars);
        updated_alpha = TurboLogicWidget::append_scalar_multiplication_inputs(key, updated_alpha, transcript, scalars);

        return updated_alpha;
    }

    static barretenberg::fr compute_quotient_evaluation_contribution(verification_key* key,
                                                                     const barretenberg::fr& alpha_base,
                                                                     const Transcript& transcript,
                                                                     barretenberg::fr& r_0)
    {
        auto updated_alpha_base = PermutationWidget::compute_quotient_evaluation_contribution(
            key, alpha_base, transcript, r_0, use_linearisation, idpolys);

        updated_alpha_base =
            TurboArithmeticWidget::compute_quotient_evaluation_contribution(key, updated_alpha_base, transcript, r_0);
        updated_alpha_base =
            TurboFixedBaseWidget::compute_quotient_evaluation_contribution(key, updated_alpha_base, transcript, r_0);
        updated_alpha_base =
            TurboRangeWidget::compute_quotient_evaluation_contribution(key, updated_alpha_base, transcript, r_0);
        updated_alpha_base =
            TurboLogicWidget::compute_quotient_evaluation_contribution(key, updated_alpha_base, transcript, r_0);

        return updated_alpha_base;
    }
};

} // namespace waffle