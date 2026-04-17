// Implementation of the C-ABI shim in VQFC.h.
//
// VQF's default build uses `double` for vqf_real_t. Swift wants float32
// (matching the braw_helper output format), so we buffer-convert at the
// boundary.

#include "VQFC.h"
#include "offline_vqf.hpp"
#include "vqf.hpp"

#include <vector>

extern "C" int vqfc_offline_6d(const float *gyr, const float *acc,
                                size_t N, float ts, float *out6D) {
    if (!gyr || !acc || !out6D || N == 0) return 1;

    std::vector<vqf_real_t> g(N * 3), a(N * 3), q(N * 4);
    for (size_t i = 0; i < N * 3; ++i) {
        g[i] = static_cast<vqf_real_t>(gyr[i]);
        a[i] = static_cast<vqf_real_t>(acc[i]);
    }

    VQFParams params;  // defaults
    offlineVQF(g.data(), a.data(),
               /*mag*/ nullptr,
               N, static_cast<vqf_real_t>(ts), params,
               /*out6D*/ q.data(),
               /*out9D*/ nullptr,
               /*outDelta*/ nullptr,
               /*outBias*/ nullptr,
               /*outBiasSigma*/ nullptr,
               /*outRest*/ nullptr,
               /*outMagDist*/ nullptr);

    for (size_t i = 0; i < N * 4; ++i) {
        out6D[i] = static_cast<float>(q[i]);
    }
    return 0;
}
