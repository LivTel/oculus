/* 
 * Show the current LMST for LT
 * My original intention was to provide various command line options to request LMST at locations
 * other than the LT and to parse date-time strings in various formats. All this can be done but I
 * am not going to spend time on it until a need for those functions arises.
 *
 *
 * For actual use on the LT we need to deal with 
 *	convert of Greenwich ST to La Palma LST
 *
 * UT1 / UTC
 * All our timestamps are actualy UTC which is based on TAI with the addition of
 * leap seconds. The entire point of leap seconds though is to keep UTC within
 * 1 second of UT1, so as long as 1 sec errors are not a problem, we can 
 * approximate UTC = UT1 and ignore the difference. 
 */

# define _POSIX_SOURCE
# define _POSIX_C_SOURCE 199309L
# define _XOPEN_SOURCE
# define _XOPEN_SOURCE_EXTENDED 
# define _GNU_SOURCE


#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include <time.h>


/* Pi is defined in the standard header files  as M_PIl and we could use that.
 * Instead we just define here the exact conversion factors we want to use */
/* 2 PI */
#define D2PI 6.2831853071795864769252867665590057683943387987502
/* Conversion factor for seconds of time to radians */
#define DS2R 7.2722052166430399038487115353692196393452995355905e-5

/* This is the time difference between LT and GMT; the real physical longitude difference, 
 * not the time zone. It is the difference between GMST and LMST.
 * -ve for west of Greenwich because the local time is "earlier". */
#define LT_TIME_DIFFERENCE	-1.191946667	/* hours */



static void echo_usage(); 		/* Print command syntax to STDOUT */
double mjd_to_gmst( double mjd );	/* MJD -> GMST */ 


int main (int argc, char**argv) 
{
  double local_time_difference;
  double gmst,lmst,mjd;
  int lmst_hours,lmst_min;
  float lmst_sec;

  /* Time, date and degrees specifications */
  char date_str[9], datetime_str[20];
  time_t unix_seconds;
  struct tm *datetime;
  struct timespec current_time;

  /* Command line parsing */
  if (argc == 1) {
    /* When called with no command line options, we do "now" at the LT */

    /* Assume LT */
    local_time_difference = LT_TIME_DIFFERENCE;

    /* Assume now */
    /* This returns an interger number of seconds, but since this function is only accurate to about
     * a second anyway, that should be OK */
    unix_seconds = time(NULL);

  } else {
    /* Here we could parse a time read from the command line */
    echo_usage();
  }

  /*printf("unix seconds = %ld\n",unix_seconds); */

  /* Convert the unix seconds to MJD. We neglect any corrections for leap seconds which would change the 
   * result by about 1 part in 10^5 during the day of leap second. his is well within the limits of
   * our 1 second stated accuracy.
   * I add 0.5 sec to unix_seconds to account for it being an integer. We are in fact somewhere "during" that second.
   */
  mjd = ( ((double)unix_seconds+0.5) / 86400.0 ) + 40587.0 ;


  /* Convert to Greenwich sideral time */
  gmst = mjd_to_gmst(mjd);
  /* Convert from radians to hours */
  gmst = gmst / D2PI * 24.0;

  /* Correct for our longitude and make sure we are still in the range 0 - 24.
   * As with earlier comments, this gets the answer wrong during a leap second. Do we care? */
  lmst = gmst + local_time_difference;
  lmst = fmod(lmst, 24.0);
  if (lmst < 0.0) lmst += 24.0;

  /* printf("unix :\t\t %lf\n",(double)unix_seconds+0.5);
   * printf("GMST :\t\t %lf\n",gmst);
   * printf("LMST :\t\t %lf\n",lmst);
   * printf("LMST :\t\t %02d:%02d:%05.2f\n",lmst_hours,lmst_min,lmst_sec); */

  /* Convert to a human readable format */
  lmst_hours = (int)lmst;
  lmst = (lmst - lmst_hours) * 60.0;
  lmst_min = (int)(lmst);
  lmst = (lmst - lmst_min) * 60.0;
  lmst_sec = (float)(lmst);

  /* printf("LMST :\t\t %02d:%02d:%05.2f\n",lmst_hours,lmst_min,lmst_sec); */
  printf("%02d:%02d:%04.1f\n",lmst_hours,lmst_min,lmst_sec);

 return 0;

}



/*
 * Convert from MJD(UT1) (JD-2400000.5) to sidereal time.
 * Based on Pat Wallace's slGMST from the FORTRAN/STARLINK slalib which in turn is derived from
 * The IAU 1982 (page S15 of Astronomical Almanac) definition.
 *
 * MJD is essentially a re-expression of UT1 so this code is also effectively providing a 
 * conversion from UT1 to GMST. The extra confusion being that you would need to parse the
 * UT datetime string.
 * 
 * | UT1 - UTC | is always less than 1 sec so try not to lose too much sleep if you actually 
 * pass UTC into this instead of UT1.
 */
double mjd_to_gmst( double mjd )
{

  double tu;
  double gmst;

  /* Julian centuries from fundamental epoch J2000 to this UT1 */
  tu = ( mjd - 51544.5 ) / 36525.0;

  /* Greenwich ST at this UT1 */
  gmst =  ( fmod ( mjd, 1.0 ) * D2PI + ( 24110.54841 + ( 8640184.812866 +
                       ( 0.093104 - 6.2e-6 * tu ) * tu ) * tu ) * DS2R );

  /* Ensure output result lies in the range 0 -> 2PI */
  gmst = fmod(gmst, D2PI);
  if (gmst < 0.0) gmst += D2PI;

  return(gmst);

}



/*
 *  Command line help
 */
void echo_usage()
{
  printf("\nlmst\n");
  printf("Return the current lmst at the LT. \n");
  printf("My original intention was to provide various command line options to request LMST at locations\n");
  printf("other than the LT and to parse date-time strings in various formats. All this can be done but I\n");
  printf("am not going to spend time on it until a need for those functions arises.\n"); 
  
  exit(1);
}

