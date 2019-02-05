#include <stdlib.h>

#include <stdio.h>

#include <time.h>

#include <unistd.h>
  
#include <string.h>

#include <sys/types.h>
#include <sys/dir.h>
#include <sys/param.h>

#define FALSE 0
#define TRUE !FALSE

void panic(char *panic_string);
void logit(char *log_string);

void make_filename(char *filename);

int file_select(struct direct *entry);

char comparison_string[80];
char datadir[80];
char prefix[80];
char exptype ='x';

int main(int argc, char* argv[])
{

  if (argc!=4) panic("must specify <exp-type> <prefix> <datadir>");

  if (strcmp(argv[1],"FLAT")==0) 
    exptype='f';
  if (strcmp(argv[1],"BIAS")==0) 
    exptype='b';
  if (strcmp(argv[1],"DARK")==0) 
    exptype='d';
  if (strcmp(argv[1],"EXPOSE")==0) 
    exptype='e';
  if (exptype=='x') panic("Exposure type not FLAT, BIAS, DARK or EXPOSE");
  strcpy(prefix,argv[2]);
  strcpy(datadir,argv[3]);



  char filename[80];
  char logstring[1000];

  make_filename(filename);
  printf("%s\n",filename);

  return 0;
}

void panic(char *panic_string) {
  printf("filename: %s\n",panic_string);
  exit(1);
}

void make_filename(char *filename) {

  time_t nowbin;

  char nowstring[80];
  const struct tm *nowstruct;

  struct direct **files;

  int day;
  int month;
  int year;
  int hour;

  int numfiles;

  //  (void)setlocale(LC_ALL,"");

  if (time(&nowbin) == (time_t)-1)
    panic("could not get time of day");
  
  nowstruct=localtime(&nowbin);

  strftime(nowstring, 80, "%d", nowstruct);
  day = atoi(nowstring);

  strftime(nowstring, 80, "%m", nowstruct);
  month = atoi(nowstring);

  strftime(nowstring, 80, "%Y", nowstruct);
  year = atoi(nowstring);

  strftime(nowstring, 80, "%H", nowstruct);
  hour = atoi(nowstring);


  if (year>2032) panic("year>2032!");


  if (hour<=11) day--;
  
  if (day==0) {
    month--;
    day=31;
    if (month==9) day=30;
    if (month==4) day=30;
    if (month==6) day=30;
    if (month==11) day=30;
    if (month==2) {
      day=28;
      if ((year==2008) ||
	  (year==2012) ||
	  (year==2016) ||
	  (year==2020) ||
 	  (year==2024) ||
 	  (year==2028) ||
 	  (year==2032)) 
	day=29;
    }
  }

  if (month==0) {
    year--;
    month=12;
    day=31;
  }


  sprintf(comparison_string,"%s_e_%d%02d%02d",prefix,year,month,day);
  numfiles=scandir(datadir, &files, file_select, alphasort);

  sprintf(comparison_string,"%s_b_%d%02d%02d",prefix,year,month,day);
  numfiles=numfiles+scandir(datadir, &files, file_select, alphasort);

  sprintf(comparison_string,"%s_d_%d%02d%02d",prefix,year,month,day);
  numfiles=numfiles+scandir(datadir, &files, file_select, alphasort);

  sprintf(comparison_string,"%s_f_%d%02d%02d",prefix,year,month,day);
  numfiles=numfiles+scandir(datadir, &files, file_select, alphasort);
  

  sprintf(filename,"%s/%s_%c_%d%02d%02d_%d_1_1_0.fits",
	  datadir,prefix,exptype,year,month,day,numfiles+1);
  
}


int file_select (struct direct *entry) {
  
  if ((strncmp(comparison_string, entry->d_name, strlen(comparison_string))==0) &&
      (strstr(entry->d_name,"0.fits")!=0))
    return (TRUE);

  return (FALSE);
}

void logit(char *log_string) {
  fprintf(stderr,"%s\n",log_string);
}
