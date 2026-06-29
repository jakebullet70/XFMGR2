
#include "ytree.h"
#include "tilde.h"
#include "xmalloc.h"
#include <curses.h>



static int  GetchStr(char *str);
static void DisplayInputLine(char *prompt, char *line, int y, int pos, BOOL fill_line);


/* Returns (left) substring of str which needs visible_count columns to be displayed */
char *StrLeft(const char *str, size_t visible_count) {
  char *result;
  size_t len;
  int left_bytes;

#ifdef WITH_UTF8
  mbstate_t state;
  const char *s;
  int pos = 0;
#endif

  if (visible_count == 0)
    return (Strdup(""));

  len = StrVisualLength(str);
  if (visible_count >= len)
    return (Strdup(str));

#ifdef WITH_UTF8

  s = str;

  while (*s) {

    wchar_t wc;
    size_t sz;
    int width;

    memset(&state, 0, sizeof(state));
    sz = mbrtowc(&wc, s, 4, &state);
    if (sz == (size_t)-1 || sz == (size_t)-2) {
      if ((*s++ & 0xc0) == 0xc0) { /* skip to next char */
        while ((*s & 0xc0) == 0x80)
          s++;
      }
    } else 
    {
      s += sz;
      width = wcwidth(wc);
      if (width >= 0)
        pos += width;
      else
        pos++;
    }

    if (pos >= visible_count)
      break; /* exceeds limit */
  }

  left_bytes = s - str;

#else
  left_bytes = visible_count;
#endif

  result = Strndup(str, left_bytes);
  return (result);
}


#if 0
char *StrRight(const char *str, size_t visible_count) {
  char *result;
  size_t visual_len;

#ifdef WITH_UTF8
  int left_bytes;
  int need_to_remove;
  mbstate_t state;
  const char *s, *s_start;
#endif

  if (visible_count == 0)
    return (Strdup(""));

  visual_len = StrVisualLength(str);
  if (visual_len <= visible_count)
    return (Strdup(str));

#ifdef WITH_UTF8

  s_start = s = str;

  need_to_remove = visual_len - visible_count;

  while (*s && (need_to_remove > 0)) {

    wchar_t wc;
    size_t sz;
    int width;

    s_start = s;
    memset(&state, 0, sizeof(state));
    sz = mbrtowc(&wc, s, 4, &state);
    if (sz == (size_t)-1 || sz == (size_t)-2) {
      if ((*s++ & 0xc0) == 0xc0) { /* skip to next char */
        while ((*s & 0xc0) == 0x80)
          s++;
      }
    } else {
      s += sz;
      width = wcwidth(wc);
      if (width >= 0)
        need_to_remove -= width;
    }
  }

  result = Strdup(s);

#else
  result = Strdup(&str[visual_len - visible_count]);
#endif

  return (result);
}
#endif



/* Returns substring of str - starting with column "visible_start", with - at most "visible_count" columns to be displayed */
/* if "visible_count" is "-1", the substring contains the rest of the string "str", starting at column "visible_start" */
char *StrMid(const char *str, size_t visible_start, int visible_count) {

  char *result;

#ifdef WITH_UTF8

  int byte_count;
  int count = 0;
  mbstate_t state;
  const char *s;
  const char *start_pos;

  if (visible_count == 0)
    return (Strdup(""));

  s = str;
  start_pos = NULL;

  while (*s) {

    wchar_t wc;
    size_t sz;
    int width;

    memset(&state, 0, sizeof(state));
    sz = mbrtowc(&wc, s, 4, &state);
    if (sz == (size_t)-1 || sz == (size_t)-2) {
      if ((*s++ & 0xc0) == 0xc0) { /* skip to next char */
        while ((*s & 0xc0) == 0x80)
          s++;
      }
    } else {
      s += sz;
      width = wcwidth(wc);
      if (width >= 0)
        count += width;
    }

    if(start_pos == NULL && count >= visible_start)
      start_pos = s;

    if(start_pos && visible_count > 0)
    {
      if((count - visible_start) > visible_count)
        break;
    }

  }

  byte_count = s - start_pos;

  result = Strndup(start_pos, byte_count);

#else

  /* Non UTF_8 */

  if(visible_count >= 0)
    result = Strndup(&str[visible_start], visible_count);
  else
    result = Strdup(&str[visible_start]);

#endif

  return (result);
}



/* returns the needed columns to display the string str */
int StrVisualLength(const char *str) {

  int len;

#ifdef WITH_UTF8

  int pos = 0;
  size_t sz;
  mbstate_t state;
  const char *s = str;
  wchar_t buffer[PATH_LENGTH + 1];

  /* convert UTF8 string to wide character string */
  do {
    memset(&state, 0, sizeof(state));
    sz = mbrtowc(&buffer[pos], s, 4, &state);
    if (sz == (size_t)-1 || sz == (size_t)-2) {
      if ((*s++ & 0xc0) == 0xc0) { /* skip to next char */
        while ((*s & 0xc0) == 0x80)
          s++;
      }
    } else {
      s += sz;
      pos++;
    }
  } while (sz != 0);

  len = wcswidth(buffer, PATH_LENGTH);

  if (len < 0)
    len = pos; /* should not happen */

#else
  len = strlen(str);
#endif

  return len;
}


/* returns the needed columns to display the first "n" characters from string str */
int StrNVisualLength(const char *str, int n) {
  int len;

#ifdef WITH_UTF8

  int pos = 0;
  int cnt = 0;
  size_t sz;
  mbstate_t state;
  const char *s = str;
  wchar_t buffer[PATH_LENGTH + 1];

  if(n <= 0)
    return 0;

  do {
    memset(&state, 0, sizeof(state));
    sz = mbrtowc(&buffer[pos], s, 4, &state);
    if (sz == (size_t)-1 || sz == (size_t)-2) {
      if ((*s++ & 0xc0) == 0xc0) { /* skip to next char */
        while ((*s & 0xc0) == 0x80)
          s++;
      }
    } else {
      s += sz;
      pos++;
      cnt++;
    }
  } while (sz != 0 && cnt < n);

  if(sz != 0)
    buffer[pos] = '\0';

  len = wcswidth(buffer, PATH_LENGTH);

  if (len < 0)
    len = pos; /* should not happen */

#else

  len = n;
  
#endif

  return len;
}



/* returns the count of characters in string str */
int StrCharacterCount(const char *str) {

  int count = 0;

#ifdef WITH_UTF8

  size_t sz;
  mbstate_t state;
  const char *s = str;

  do {
    memset(&state, 0, sizeof(state));
    sz = mbrtowc(NULL, s, 4, &state);
    if (sz == (size_t)-1 || sz == (size_t)-2) {
      if ((*s++ & 0xc0) == 0xc0) { /* skip to next char */
        while ((*s & 0xc0) == 0x80)
          s++;
      }
    } else if(sz > 0) {
      s += sz;
      count++;
    }
  } while (sz != 0);

#else
  count = strlen(str);
#endif

  return count;
}



/* returns byte position for visual position */
int VisualPositionToBytePosition(const char *str, int visual_pos) {

#ifdef WITH_UTF8

  mbstate_t state;
  const char *s, *s_start;
  int pos = 0;

  s_start = s = str;

  while (*s) {

    wchar_t wc;
    size_t sz;
    int width;

    s_start = s;
    memset(&state, 0, sizeof(state));
    sz = mbrtowc(&wc, s, 4, &state);
    if (sz == (size_t)-1 || sz == (size_t)-2) {
      if ((*s++ & 0xc0) == 0xc0) { /* skip to next char */
        while ((*s & 0xc0) == 0x80)
          s++;
      }
    } else {
      s += sz;
      width = wcwidth(wc);
      if (width > 0)
        pos += width;
      else
        pos++;
    }

    if (pos > visual_pos)
      return (s_start - str);
  }

  return (s - str);

#else
  return visual_pos;
#endif
}




static void DisplayInputLine(char *prompt, char *line, int y, int pos, BOOL fill_line)
{
  int i, n, pos_col;
  int prompt_length = 0;
  int x_linestart_pos;
  int x_left_indicator_pos;
  int x_right_indicator_pos;
  int x_offset = 0;
  int max_visible_characters;


  if(prompt)
  {
    prompt_length = StrVisualLength(prompt);
    MvAddStr(y, 1, prompt);  /* prompt is always visible */
  }

  x_left_indicator_pos = prompt_length + 1;
  x_right_indicator_pos = COLS - 1;
  x_linestart_pos = prompt_length + 2; /* x position of line content start */

  max_visible_characters = COLS - x_linestart_pos - 1;
  if(max_visible_characters <= 0)
    return;  /* nothing to display... */

  if(pos >= max_visible_characters)
    x_offset = VisualPositionToBytePosition(line, pos - max_visible_characters + 1);
    
  n = VisualPositionToBytePosition(&line[x_offset], max_visible_characters);

  MvAddNStr(y, x_linestart_pos, &line[x_offset], n);  
  for (i = getcurx(stdscr); i < COLS - 1; i++)
    addch((fill_line) ? '_' : ' ');

  /* set/reset scroll indicators */
  MvAddStr(y, x_left_indicator_pos, (x_offset > 0) ? "<" : " ");
  MvAddStr(y, x_right_indicator_pos, (StrVisualLength(&line[x_offset]) > max_visible_characters) ? ">" : " ");

  /* set cursor */
  if(pos >= max_visible_characters)
    wmove(stdscr, y, x_linestart_pos + max_visible_characters - 1);
  else {
    pos_col = StrNVisualLength(line, pos);
    wmove(stdscr, y, x_linestart_pos + pos_col);
  }
}


/***************************************************************************
 * InputStr                                                                *
 * prompts for a string on line y                                          *
 * Default value - and output is s                                         *
 * Return value is the key which terminates the function (or -1 on error)  *
 ***************************************************************************/


int InputString (char *prompt,
                 char *s,                       /* input/output string */
                 int  length,                   /* buffer length of s  */
                 int  y, int cursor_pos,        /* visual position on screen     */
                 char *term)                    /* set of termination characters */
{
  int  n, pos = 0; 
  int  input_char;
  int  pos_col;
  char input_str[5];
  char *pp;
  char path[PATH_LENGTH + 1];
  char *ls, *rs;
  BOOL done = FALSE;
  static BOOL insert_flag = TRUE;


  if (COLS < 6)
    return -1;

  input_str[0] = '\0';

  curs_set(1);
  leaveok(stdscr, FALSE);

  DisplayInputLine(prompt, s, y, 0, TRUE);

  if(cursor_pos <= StrVisualLength(s))
    pos = cursor_pos;

  do {

    input_char = GetchStr(input_str);  /* Get multibyte input string - if UTF8 is enabled , else string contains only one byte */

    if (input_char != ERR) {

      if (input_char == LF)
        input_char = CR;

      if(input_char == ('C' & 0x1f)) /* handle Ctrl C like ESC */
        input_char = ESC;

      if(input_char < 0x20)
        *input_str = '\0';

      /* Evaluate input character */
      switch (input_char) {

      case KEY_LEFT:
        if (pos > 0)
          pos--;
        else
          beep();
        break;

      case KEY_RIGHT:
        if( pos < StrCharacterCount(s) )
          pos++;
        else
          beep();
        break;

      case KEY_UP:
        pp = GetHistory();
        if (pp == NULL)
          break;
        if (*pp) {
          ls = StrLeft(pp, length);
          strcpy(s, ls);
          free(ls);
          pos = StrCharacterCount(s);
        }
        break;

      case KEY_HOME:
        pos = 0;
        break;

      case KEY_END:
        pos = StrCharacterCount(s);
        break;

      case KEY_DC:
        n = StrCharacterCount(s);
        if (pos < n) {
          pos_col = StrNVisualLength(s, pos);
          ls = StrLeft(s, pos_col);
          rs = StrMid(s, pos_col + 1, -1);
          strcpy(s, ls);
          strcat(s, rs);
          free(ls);
          free(rs);
        }
        else 
          beep();
        break;

      case 0x08:
      case 0x7F:
      case KEY_BACKSPACE:
        if (pos > 0) {
          pos_col = StrNVisualLength(s, pos - 1);
          ls = StrLeft(s, pos_col);
          rs = StrMid(s, pos_col + 1, -1);
          strcpy(s, ls);
          strcat(s, rs);
          free(ls);
          free(rs);
          pos--;
        } else
          beep();
        break;

      case KEY_DL:
        ls = StrLeft(s, pos);
        strcpy(s, ls);
        free(ls);
        break;

      case KEY_EIC:
      case KEY_IC:
        insert_flag ^= TRUE;
        /* curs_set( (insert_flag) ? 1 : 2 ); */
        break;

      case '\t':
        if ((pp = GetMatches(s)) == NULL) {
          beep();
          break;
        }
        if (*pp) {
          ls = StrLeft(pp, length);
          if(strlen(ls) > length)
            beep();
          else 
          {
            strcpy(s, ls);
            pos = StrCharacterCount(s);
          }
          free(ls);
          free(pp);
        }
        break;

#ifdef KEY_F
      case KEY_F(2):
#endif
      case 'F' & 0x1f:
        if (KeyF2Get(statistic.tree, statistic.disp_begin_pos,
                      statistic.cursor_pos, path)) {
          /* beep(); */
          break;
        }
        if (*path) 
        {
          ls = StrLeft(path, length);
          if(strlen(ls) > length)
            beep();
          else
          {
            strcpy(s, ls);
            pos = StrCharacterCount(s);
          }
          free(ls);
        }
        break;

      default:

        if (*input_str) 
        {        
          /* handle visible character */

          int slen = strlen(s);
          int input_str_len = strlen(input_str);

          if (insert_flag) 
          {
            if( pos >= StrCharacterCount(s) )
            {
              /* append symbol */
              if((slen + input_str_len) > length)
                beep();
              else
              {
                strcat(s, input_str);
                pos++;
              }
            }
            else 
            {
              /* insert symbol at cursor position */
              if (pos > 0)
              {
                ls = StrLeft(s, pos);
                pos_col = StrNVisualLength(s, pos);
                rs = StrMid(s, pos_col, -1);
              } else {
                ls = Strdup("");
                rs = Strdup(s);
              }

              if((strlen(ls) + input_str_len + strlen(rs)) > length)
                beep();
              else
              {
                strcpy(s, ls);
                strcat(s, input_str);
                strcat(s, rs);
                pos++;
              }
              free(ls);
              free(rs);
            }
          } 
          else 
          {
            /* owerwrite symbol at cursor position */
            if( pos >= StrCharacterCount(s) )
            {
              if((slen + input_str_len) > length)
                beep();
              else
              {
                strcat(s, input_str);
                pos++;
              }
            } 
            else 
            {
              ls = StrLeft(s, pos);
              pos_col = StrNVisualLength(s, pos + 1);
              rs = StrMid(s, pos_col, -1);
              
              if((strlen(ls) + input_str_len + strlen(rs)) > length)
                beep();
              else
              {
                strcpy(s, ls);
                strcat(s, input_str);
                strcat(s, rs);
                pos++;
              }
              free(ls);
              free(rs);
            }
          }
          *input_str = '\0';
        }
        break;
      } /* switch */
    } /* else control symbols */

    if(input_char == 27 || input_char == CR)
      done = TRUE;

    /* visualize/update current input line */
    if(done)
      DisplayInputLine(prompt, s, y, 0, FALSE);  
    else
      DisplayInputLine(prompt, s, y, pos, TRUE);
    
  } while (!done);

  leaveok(stdscr, TRUE);
  curs_set(0);
  InsHistory(s);

#ifdef READLINE_SUPPORT
  pp = tilde_expand(s);
  strncpy(s, pp, length - 1);
  s[length] = '\0';
  xfree(pp);
#endif

  return (input_char);
}



int InputChoise(char *msg, char *term) {
  int c;

  ClearHelp();

  curs_set(1);
  leaveok(stdscr, FALSE);
  mvprintw(LINES - 2, 1, "%s", msg);
  RefreshWindow(stdscr);
  doupdate();
  do {
    c = Getch();
    if (c >= 0)
      if (islower(c))
        c = toupper(c);
  } while (c != -1 && !strchr(term, c));

  if (c >= 0)
    echochar(c);

  move(LINES - 2, 1);
  clrtoeol();
  leaveok(stdscr, TRUE);
  curs_set(0);

  return (c);
}


int GetTapeDeviceName(void) {
  int result;
  char path[PATH_LENGTH * 2 + 1];

  result = -1;

  ClearHelp();

  (void)strcpy(path, statistic.tape_name);

  if (InputString("Tape-Device:", path, sizeof(path) - 1, LINES - 2, 0, "\r\033") == CR) {
    result = 0;
    (void)strcpy(statistic.tape_name, path);
  }

  move(LINES - 2, 1);
  clrtoeol();

  return (result);
}


void HitReturnToContinue(void) {
#ifndef XCURSES
  curs_set(1);
  vidattr(A_REVERSE);
  putp("[Hit return to continue]");
  vidattr(0);
  (void)fflush(stdout);
  (void)Getch();
#endif /* XCURSES */
  curs_set(0);
  doupdate();
}


BOOL KeyPressed() {
  BOOL pressed = FALSE;

#if !defined(linux) || !defined(TERMCAP)
  nodelay(stdscr, TRUE);
  if (WGetch(stdscr) != ERR)
    pressed = TRUE;
  nodelay(stdscr, FALSE);
#endif /* linux/TERMCAP */

  return (pressed);
}


BOOL EscapeKeyPressed() {
  BOOL pressed = FALSE;
  int c;

#if !defined(linux) || !defined(TERMCAP)
  nodelay(stdscr, TRUE);
  if ((c = WGetch(stdscr)) != ERR)
    pressed = TRUE;
  nodelay(stdscr, FALSE);
#endif /* linux/TERMCAP */

  return ((pressed && c == ESC) ? TRUE : FALSE);
}

#ifdef VI_KEYS

int ViKey(int ch) {
  switch (ch) {
  case VI_KEY_UP:
    ch = KEY_UP;
    break;
  case VI_KEY_DOWN:
    ch = KEY_DOWN;
    break;
  case VI_KEY_RIGHT:
    ch = KEY_RIGHT;
    break;
  case VI_KEY_LEFT:
    ch = KEY_LEFT;
    break;
  case VI_KEY_PPAGE:
    ch = KEY_PPAGE;
    break;
  case VI_KEY_NPAGE:
    ch = KEY_NPAGE;
    break;
  }
  return (ch);
}

#endif /* VI_KEYS */

#ifdef _IBMR2
#undef wgetch

int AixWgetch(WINDOW *w) {
  int c;

  if ((c = WGetch(w)) == KEY_ENTER)
    c = LF;

  return (c);
}

#endif


int WGetch(WINDOW *win) {
  int c;

  c = wgetch(win);

#ifdef KEY_RESIZE
  if (c == KEY_RESIZE) {
    resize_request = TRUE;
    c = ERR;
  }
#endif

  return (c);
}


int Getch() 
{ 
  return (WGetch(stdscr)); 
}


/* Get character from console as keycode and string */
static int GetchStr(char *str)  
{

#ifdef WITH_UTF8

  wint_t  ch;
  mbstate_t state;
  size_t s;
  int res;

  res = get_wch(&ch);

  if(res == OK)
  {
    memset(&state, 0, sizeof(state));
    s = wcrtomb(str, (wchar_t)ch, &state);

    if(s > 0)
    {
      str[s] = '\0';
      return ch;
    }

    str[0] = '\0';
    beep();
    
    return ERR; 
  } 
  else if( res == KEY_CODE_YES)
  {
    str[0] = '\0';
    return ch;
  }

  return ERR;

#else

  /* Non-UTF8 */

  int ch = Getch();

  str[0] = (ch >= ' ' && ch <= 0xff && ch != 127) ? (char) ch : '\0';
  str[1] = '\0';

  return ch;

#endif

}
