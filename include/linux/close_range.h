/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_CLOSE_RANGE_H
#define _LINUX_CLOSE_RANGE_H

#include <uapi/linux/close_range.h>

int __close_range(unsigned fd, unsigned max_fd, unsigned int flags);

#endif /* _LINUX_CLOSE_RANGE_H */
