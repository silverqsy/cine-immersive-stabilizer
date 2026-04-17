// C-ABI shim over VQF's C++ offlineVQF for Swift consumption.
//
// Only exposes what we need: 6D (gyro+accel) offline fusion with default
// parameters. Produces one unit quaternion (w, x, y, z) per IMU sample.
//
// All arrays are row-major float32.

#ifndef VQFC_H
#define VQFC_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Run VQF offline 6D fusion.
///
/// @param gyr  flat [N*3] float32 gyro (rad/s), XYZ per sample
/// @param acc  flat [N*3] float32 accel (m/s²), XYZ per sample
/// @param N    number of samples
/// @param ts   sample period in seconds (1/sample_rate)
/// @param out6D flat [N*4] float32 output quaternions (w,x,y,z per sample)
/// @return 0 on success, non-zero on error
int vqfc_offline_6d(const float *gyr, const float *acc,
                    size_t N, float ts, float *out6D);

#ifdef __cplusplus
}
#endif

#endif /* VQFC_H */
