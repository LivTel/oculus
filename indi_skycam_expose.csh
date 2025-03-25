#!/bin/tcsh

# Script to do a single $exptime exposure via indiserver library
#       Oculus all-sky uses 30sec
#       skycamT still testing. 10sec - 30sec seems about right
#
# Uses indi config item, UPLOAD_SETTINGS.UPLOAD_DIR. You may need to upgrade the
# indiserver on oculus before this script can be used. The indiserver originally
# installed on oculus did not have that config item.
#
# Original function code that actually takes images: IAS 12th June 2014
# All the wrappers, locks, xfer, FITS headers etc: RJS 13th June 2014
# Extended to use per instrument config files, RJS, Feb 2019
#
# The indiserver we connect to is started on boot in /etc/rc.local or
# via the ICS autobooter as it needs to run as root.
#
# The camera USB needs to be plugged in on boot therefore.


# Source the setup script.
# Using the same setup between this and the exposure script guarantees both are using the same settings. 
source /usr/local/bin/indi_skycam_setup.csh
set procname = indi_skycam_expose.csh

if ($DEBUG) echo `datestamp` $hostname ${procname}: Proceed to checking dome >> $LOGFILE


########################################
# Only take an image if the dome is open
########################################

# $FORCE_TELDATA allows us to totally ignore the http://192.168.4.1/teldata system.
# E.g., for testing the camera off-site
# ($FORCE_TELDATA == 0) is the normal state. It would only ever be set 'ON' in rare diagnostic tests. 
# Never run that way on sky.

if ($FORCE_TELDATA) then
  echo "FORCE_TELDATA is set. Will not even try to get http://192.168.4.1/teldata" >> $LOGFILE
else
  # http://192.168.4.1/teldata takes several seconds to be generated, so we need to make sure we have not
  # collected a half written version. If we have then we just try again. The loopct is here so that 
  # we do not get into an infinite loop of the http://192.168.4.1/teldata system fails. We will give up 
  # after five attempts.
  set loopct = 0
  while ( $loopct < 5 ) 
    if ($DEBUG) then
      wget --timeout 5 http://192.168.4.1/teldata -O /tmp/teldata >>& $LOGFILE
    else 
      wget --timeout 5 http://192.168.4.1/teldata -O /tmp/teldata >>& /dev/null
    endif
    # grep for what we know should be in the completed teldata file and if it is there then break from the loop 
    grep "Object recvd" /tmp/teldata >& /dev/null
    if ($status == 0) break 			# Good. Required data found. Jump out of loop
    if ($DEBUG) echo "/tmp/teldata does not contain the string 'Object recvd'" >> $LOGFILE
    #if ($DEBUG) cat /tmp/teldata >> $LOGFILE
    if ($DEBUG) echo `datestamp` $hostname ${procname}: "Retry wget after a 2 sec sleep" >> $LOGFILE
    sleep 2
    @ loopct++
  end

  # Send stderr to /dev/null because I don't care if the file does not exist 
  rm /tmp/enclosure-open /tmp/enclosure-closed >& /dev/null

  tail -1 /tmp/teldata | grep "OPEN" >! /tmp/enclosure-open
  tail -1 /tmp/teldata | grep "CLOSED" >! /tmp/enclosure-closed
endif

# Check if either dome is open or the --forcedome option was set
if ($FORCE_DOME) then
  if ($DEBUG) echo `datestamp` $hostname ${procname}: "Enclosure ignored by --forcedome option" >> $LOGFILE
else
  if (!(-z /tmp/enclosure-closed)) then 
    if ($DEBUG) echo `datestamp` $hostname ${procname}: "enclosure closed" >> $LOGFILE
    goto ENC_CLOSED
  endif
  if ($DEBUG) echo `datestamp` $hostname ${procname}: "enclosure open" >> $LOGFILE
endif



#####################################################
# COLLECT VALUES THAT WILL NEED TO GO INTO THE HEADER
#####################################################

# delete old temporary output file if there is one
rm -f "${datadir}/${inst_letter}_IMAGE_"*.fits >& /dev/null

# generate LT style standard filename
set fname = ` $FILENAME EXPOSE $inst_letter $datadir `
if ($DEBUG) echo `datestamp` $hostname ${procname}:  File name will be $fname >> $LOGFILE

# Will get written in FITS header later
set ccdatemp = `indi_getprop -1 -p 7264 "${HARDWARE_NAME}.CCD_TEMPERATURE.CCD_TEMPERATURE_VALUE"`

# Record the LMST now, before the integration. It is not accurately the time the shutter opened
# but it is close enough for most purposes. 
set lmst = ` $LMST `
#if ($DEBUG) echo `datestamp` $hostname ${procname}:  LMST = $lmst >> $LOGFILE



##################
# ACTUAL EXPOSURES
##################

# Take a $MULTRUN x $EXPTIME multrun
set ct = 0
while($ct < $MULTRUN)
  if ($DEBUG) echo `datestamp` $hostname ${procname}:  Start $EXPTIME sec exposure >> $LOGFILE
  indi_setprop -p 7264 "${HARDWARE_NAME}.CCD_EXPOSURE.CCD_EXPOSURE_VALUE=${EXPTIME}"
  sleep $OVERHEAD
  @ ct++
  # Parse return value from CCD_EXPOSURE.CCD_EXPOSURE_VALUE as a string, not as a number.
  while ( `indi_getprop -1 -p 7264 "${HARDWARE_NAME}.CCD_EXPOSURE.CCD_EXPOSURE_VALUE"` != "0" )
    printf "remaining %s sec\n" `indi_getprop -1 -p 7264 "${HARDWARE_NAME}.CCD_EXPOSURE.CCD_EXPOSURE_VALUE"` >> $LOGFILE
    sleep 1
  end
  if ($DEBUG) printf "\n"  >> $LOGFILE
end

# Make sure output file has finished writing to disk
sleep 1

# Check the expected output file exists 
if (! -e ${datadir}/${inst_letter}_IMAGE_001.fits ) then
  echo `datestamp` $hostname ${procname}: "ERROR : No output image (${datadir}/${inst_letter}_IMAGE_001.fits) from indiserver" >> $LOGFILE

  # Disconnect from the server. That will force the script to reconnect and attempt to reinitialise everything next time
  echo `datestamp` $hostname ${procname}: " Disconnect from indiserver" >> $LOGFILE
  indi_setprop -p 7264 "${HARDWARE_NAME}.CONNECTION.DISCONNECT=On"
  sleep 3
  indi_getprop -p 7264 "${HARDWARE_NAME}.CONNECTION.CONNECT" >> $LOGFILE

  exit 1
else 

  # Rename the indi output file to LT standard filename
  # In fact indiserver is capable of doing this itself now. See note in UPLOAD configs above.

  mv "${datadir}/${inst_letter}_IMAGE_001.fits" $fname

  # Set GAIN and EPERDN keyword values
  # But if $GAINCONFIG is set in the cfg file, save it for reference. Rename the existing GAIN keyword to GAINCONF
  if ( ${?GAINCONFIG} ) $FAKVC $fname GAINCONF STRING `$FGKV $fname GAIN STRING` "" "Gain mode setting"
  if ( ${?GAINOFFSET} ) $FAKVC $fname GAINOFFS STRING `$FGKV $fname OFFSET STRING` "" "Gain Offset mode setting"
  # Now set the numerical gain instead
  $FAKVC $fname GAIN DOUBLE ${gain_eperdn} "electrons per count" ""
  $FAKVC $fname EPERDN DOUBLE ${gain_eperdn} "electrons per count" ""

  if ($DEBUG) echo `datestamp` $hostname ${procname}: Update all the FITS headers in $fname >> $LOGFILE
  # Add LST to the FITS header. This is LST just before the oculus code was called, not the moment the shutter opened
  $FAKV $fname LST STRING "${lmst}"

  if ($FORCE_TELDATA) then
    echo "FORCE_TELDATA is set. Cannot transcribe RCS and TCS data into FITS header" >> $LOGFILE
  else
    $FAKV $fname AZDMD DOUBLE `grep "Azimuth demand" /tmp/teldata | awk '{print $4}' `
    $FAKV $fname AZIMUTH DOUBLE `grep "Current Azimuth position" /tmp/teldata | awk '{print $4}'`
    $FAKV $fname AZSTAT STRING `grep "Azimuth status" /tmp/teldata | awk '{print $4}'`

    $FAKV $fname ALTDMD DOUBLE `grep "Altitude demand" /tmp/teldata | awk '{print $4}'`
    $FAKV $fname ALTITUDE DOUBLE `grep "Current Altitude position" /tmp/teldata | awk '{print $4}'`
    $FAKV $fname ALTSTAT STRING `grep "Altitude status" /tmp/teldata | awk '{print $4}'`

    $FAKV $fname ENC1DMD STRING `grep "Enclosure shutter 1 demand" /tmp/teldata | awk '{print $6}'`
    $FAKV $fname ENC1POS STRING `grep "Enclosure shutter 1 current" /tmp/teldata | awk '{print $6}'`
    $FAKV $fname ENC2DMD STRING `grep "Enclosure shutter 2 demand" /tmp/teldata | awk '{print $6}'`
    $FAKV $fname ENC2POS STRING `grep "Enclosure shutter 2 current" /tmp/teldata | awk '{print $6}'`
  endif

  # Transcribe existing FITS keywords into our standard LT versions
  $FAKV $fname UTSTART STRING `$FGKV $fname DATE-OBS STRING `
  $FAKV $fname CCDXBIN INT `$FGKV $fname XBINNING INT `
  $FAKV $fname CCDYBIN INT `$FGKV $fname YBINNING INT `

  #LT convention is to write pixel dimension in m. This camera writes the value in micron
  #set pixsizemicron = `$FGKV $fname PIXSIZE1 INT `
  #set pixsizem = `echo "7k $pixsizemicron 1e6 / p" | dc`
  # But for now I am just going to transcribe the micron value
  $FAKVC $fname CCDXPIXE DOUBLE `$FGKV $fname PIXSIZE1 DOUBLE ` "um" "Physical pixel size"
  $FAKVC $fname CCDYPIXE DOUBLE `$FGKV $fname PIXSIZE2 DOUBLE ` "um" "Physical pixel size"

  # In quicksky, JMM uses keyword DATE in the form YYYY-MM-DD. I can create that from DATE-OBS
  $FAKV $fname DATE STRING `$FGKV $fname DATE-OBS STRING | sed 's/T.*//'`

  $FAKV $fname INSTRUME STRING $INSTRUMENT_NAME
  $FAKVC $fname CCDATEMP DOUBLE $ccdatemp "C" "Detector temperature"

  if ($DEBUG) echo `datestamp` $hostname ${procname}: Success. >> $LOGFILE
endif


######################################
# What to do if enclosure is closed
ENC_CLOSED:
#nothing!

# cleanup gets done at the end of any run but we also jump here automatically if
# the script process gets killed
cleanup:
/usr/bin/lockfile-remove $LOCK

if ($DEBUG) echo `datestamp` $hostname ${procname}: Exit script. >> $LOGFILE
exit 0

