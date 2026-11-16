/*
 * pam_cryptsetup_keyring: hands the passphrase the encrypted disk was
 * opened with at boot to the modules after it, as the password (PAM_AUTHTOK),
 * so that pam_gnome_keyring unlocks the login keyring with it at an
 * automatic login, which has no password of its own.
 *
 * The passphrase is the "cryptsetup" key of type "user" that cervino-desktop's
 * disk-passphrase leaves in root's user keyring in the initramfs (as
 * systemd-cryptsetup does on other distributions). This does what GDM's
 * pam_gdm does when it is built with keyutils, which Alpine's isn't.
 *
 * Without the key (an unencrypted disk, the key timed out) it does nothing.
 *
 * SPDX-License-Identifier: Apache-2.0
 */

#include <stdlib.h>
#include <string.h>

#include <keyutils.h>
#include <security/pam_modules.h>

int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
	key_serial_t key;
	void *pass = NULL;
	long len;
	int r;

	(void)flags;
	(void)argc;
	(void)argv;

	/* request_key, then /proc/keys for a key the keyrings don't reach. */
	key = find_key_by_type_and_desc("user", "cryptsetup", 0);
	if (key <= 0)
		return PAM_IGNORE;
	len = keyctl_read_alloc(key, &pass);
	if (len <= 0) {
		free(pass);
		return PAM_IGNORE;
	}

	/* keyctl_read_alloc ends it with a NUL. */
	r = pam_set_item(pamh, PAM_AUTHTOK, pass);
	explicit_bzero(pass, (size_t)len);
	free(pass);
	return r == PAM_SUCCESS ? PAM_SUCCESS : PAM_IGNORE;
}

int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc, const char **argv)
{
	(void)pamh;
	(void)flags;
	(void)argc;
	(void)argv;
	return PAM_IGNORE;
}
