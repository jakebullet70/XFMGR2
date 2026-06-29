/***************************************************************************
 *
 * Enhanced Curses Functions
 *
 ***************************************************************************/



#include "ytree.h"



int MvAddStr(int y, int x, char *str)
{
#ifdef WITH_UTF8
  mvaddstr(y, x, str);
#else
  for(;*str != '\0';str++)
      mvaddch(y, x++, PRINT(*str));
#endif
  return 0;
}

int MvWAddStr(WINDOW *win, int y, int x, char *str)
{
#ifdef WITH_UTF8
  mvwaddstr(win, y, x, str);
#else
  for(;*str != '\0';str++)
      mvwaddch(win, y, x++, PRINT(*str));
#endif
  return 0;
}

int WAddStr(WINDOW *win, char *str)
{
#ifdef WITH_UTF8
  waddstr(win, str);
#else
  for(;*str != '\0';str++)
      waddch(win, PRINT(*str));
#endif
  return 0;
}

int AddStr(char *str)
{
#ifdef WITH_UTF8
  addstr(str);
#else
  for(;*str != '\0';str++)
      addch( PRINT(*str));
#endif
  return 0;
}


int WAddNStr(WINDOW *win, char *str, int n)
{
#ifdef WITH_UTF8
  waddnstr(win, str, n);
#else
  int i;
  for(i=0;*str != '\0' && i < n;str++, i++)
      waddch(win, PRINT(*str));
#endif
  return 0;
}

int AddNStr(char *str, int n)
{
#ifdef WITH_UTF8
  addnstr(str, n);
#else
  int i;
  for(i=0;*str != '\0' && i < n;str++, i++)
      addch( PRINT(*str));
#endif
  return 0;
}


int MvAddNStr(int y, int x, char *str, int n)
{
#ifdef WITH_UTF8
  mvaddnstr(y, x, str, n);
#else
  int i;
  for(i=0;*str != '\0' && i < n;str++, i++)
      mvaddch(y, x++, PRINT(*str));
#endif
  return 0;
}

int MvWAddNStr(WINDOW *win, int y, int x, char *str, int n)
{
#ifdef WITH_UTF8
  mvwaddnstr(win, y, x, str, n);
#else
  int i;
  for(i=0;*str != '\0' && i < n;str++, i++)
      mvwaddch(win, y, x++, PRINT(*str));
#endif
  return 0;
}



int WAttrAddStr(WINDOW *win, int attr, char *str)
{
  int rc; 

  wattrset( win, attr );
  rc = WAddStr(win, str);
  wattrset( win, 0 );

  return(rc);
}

