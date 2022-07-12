#!/bin/tcsh

# There is no strong reason for this to run on the oculus machine. Originally I 
# expected to run it on ltproxy. You cannot currently run it on ltproxy because of
# incompatible openssl/TLS versions. Once ltproxy is brought in line with all the
# other systems, it can optionally be moved there. Running on oculus (since that is
# the source of the image data) seemed the second more logical place for this script.

# Set the API key, provided by Sebastian
# Do not check the real API key into github!
set APIKEY = 1234567890abcdef1234567890abcdef

# Set this wget parameter to ignore TLS certificate failures
set IGNORE_TLS = "--no-check-certificate"
#set IGNORE_TLS = ""

set YYYYmmdd = `/bin/date -u +%Y%m%d`
set HHMM = `/bin/date -u +%H%M`
set ss = `/bin/date -u +%s`
# Date and time in filename is when image was retrieved. Actual time of image is obviously
# before that
set opname = /var/tmp/sebcloud_${YYYYmmdd}_${HHMM}_$ss

set LMST = `/usr/local/bin/lmst`

set sebcloud_png = /home/eng/SebCloud/sebcloud_${YYYYmmdd}_${HHMM}_$ss.png
set sebcloud_json = /home/eng/SebCloud/sebcloud_${YYYYmmdd}_${HHMM}_$ss.json
set sebcloud_stat = /home/eng/SebCloud/sebcloud_${YYYYmmdd}_${HHMM}_$ss.stat

set box_allsky = 400
set box_large = 100
set box_small = 5

wget -q $IGNORE_TLS "https://orm.buntin.science/api/cloud/pattern?apikey=${APIKEY}&ra=${LMST}&dec=28:45:44.8&rad=${box_allsky}" -O $sebcloud_png
wget -q $IGNORE_TLS "https://orm.buntin.science/api/cloud?apikey=${APIKEY}&ra=${LMST}&dec=28:45:44.8&rad=${box_large}" -O $sebcloud_json
#wget -q "https://orm.buntin.science/api/cloud?apikey=${APIKEY}&ra=${LMST}&dec=28:45:44.8&rad=${box_small}" -O $sebcloud_json

set sebcloud = `cat $sebcloud_json | tr ":," " " | awk '{print $2}' `
echo $YYYYmmdd $HHMM $ss $sebcloud >! $sebcloud_stat

cp $sebcloud_stat /mnt/skycamdata/latest_SebCloud
