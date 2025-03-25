# oculus
Control software for oculus camera. Also used on new skycamT after Jan 2019 and skycamZ after Oct 2024.

Developed from oculus.csh. Now indi_skycam.csh does all skycams ATZ, using different config files.

See oculus_install.txt for installation details.

# Update 2025-03-25 - indi_auto_setup.csh

Previously, indi_skycam.csh took exposures and indi_auto_darks.csh took darks. But the two scripts
are almost entirely the same. All the file locking, housekeeping, camera config code was duplicated which
is a maintenance headache to keep them consistent.

Now indi_auto_setup.csh contains all the duplicated code and gets called by indi_skycam_expose.csh and indi_skycam_auto_darks.csh,
meaning that i) updating the code is simpler and ii) it guarantees both scripts are using the same locking code
and instrument configs.

At the time of writing, only skycamz has been upgraded to use indi_auto_setup.csh. Other skycams should be updated
to this new version whenever a new deployment is made and then this comment can be deleted.
