/*
 * SPDX-License-Identifier: MIT
 *
 * gnuarmemb's newlib: exit() -> __libc_fini_array() -> _fini(), which normally comes from
 * crti.o. Zephyr links without start files, so anything that references exit() (mbedTLS's
 * platform layer does, once Bluetooth pulls it in) fails to link. Nothing runs at exit on
 * this target, so an empty _fini is correct.
 */

void _fini(void)
{
}
