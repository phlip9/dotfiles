# greetd skips PAM auth during autologin, leaving GNOME Keyring locked. Run
# initial_session.service's auth stack so it can load the LUKS passphrase.
# Remove this patch once upstream supports this autologin PAM path.
{ greetd }:
greetd.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./initial-session-pam.patch ];
})
