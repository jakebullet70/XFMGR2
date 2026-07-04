%encoding iso
%import strings
%import floats


time_t {


ubyte[13] MONTH_DAYS = [0,31,28,31,30,31,30,31,31,30,31,30,31]
ubyte sYear
ubyte sMonth
ubyte sDay
ubyte sHours
ubyte sMins
ubyte sSecs
ubyte sWeekDay
ubyte sJiffies
long sTimer
long Tmp_T
long passed_Jiffies

const uword MINS_PER_DAY = 1440

sub IsALeapYear(uword lYear) -> bool {
  return (((lYear % 4)==0) and ((lYear % 100) != 0)) or ((lYear % 400)==0)
}

sub fmod(float Target, float Divisor) -> float {
    return Target - (floats.floor(Target/Divisor) * Divisor)
}

sub UnixTimeT_TO_RTC(float UnixTime) {

 float RemainingSeconds = fmod(UnixTime, 86400)
 ubyte tHour = floats.floor(RemainingSeconds/3600) as ubyte

 RemainingSeconds = fmod(RemainingSeconds, 3600)
 ubyte tMin = floats.floor(RemainingSeconds/60) as ubyte
 ubyte tSec = fmod(RemainingSeconds, 60) as ubyte

 float TotalDays = floats.floor(UnixTime / 86400)

 ; Jan 01, 1970 is Thursday
 ubyte tWeekDay = (fmod(TotalDays, 7) + 5) as ubyte
 if tWeekDay > 7 { tWeekDay -= 7 }

 uword curYear = 1970
 float YearDays
 do {
    if IsALeapYear(curYear)
     { YearDays = 366 }
    else
     { YearDays = 365 }

   if TotalDays >= YearDays {
      TotalDays -= YearDays
      curYear++
    }
 } until TotalDays <= YearDays

 if IsALeapYear(curYear) { MONTH_DAYS[2]=29 } else { MONTH_DAYS[2]=28 }

 ubyte curMonth = 1
 uword curDay = (TotalDays + 1) as uword

 while curDay > MONTH_DAYS[curMonth] {
     curDay -= MONTH_DAYS[curMonth]
     curMonth++
 }

 alias tMonth = curMonth
 ubyte tYear = (curYear - 1900) as ubyte
 ; fat32 does not accomodate
 ; filedates before 1980
 if tYear < 80 { tYear = 80 }

 cx16.clock_set_date_time(mkword(tMonth,tYear),mkword(tHour,lsb(curDay)),mkword(tSec,tMin),mkword(tWeekDay,0))
 ; txt.nl()
 ; txt.nl()
 ; txt.print(" Year: ") txt.print_ub(tYear) txt.nl()
 ; txt.print("  Mon: ") txt.print_ub(tMonth) txt.nl()
 ; txt.print("  Day: ") txt.print_ub(tDay) txt.nl()
 ; txt.print("   Hr: ") txt.print_ub(tHour) txt.nl()
 ; txt.print("  Min: ") txt.print_ub(tMin) txt.nl()
 ; txt.print("  Sec: ") txt.print_ub(tSec) txt.nl()
 ; txt.nl()
 ; txt.nl()
 ; sys.wait(30)
}



sub GetStartTime() {
    %asm {{
      jsr $FF50 ; clock_get_date_time
    }}
    sYear = lsb(cx16.r0)
    sMonth = msb(cx16.r0)
    sDay = lsb(cx16.r1)
    sHours = msb(cx16.r1)
    sMins = lsb(cx16.r2)
    sSecs = msb(cx16.r2)
    sJiffies = lsb(cx16.r3)
    sWeekDay = msb(cx16.r3)
}

sub Reset_CLOCKS() {
long NewHours
ubyte NewMinutes
ubyte NewSeconds

    MONTH_DAYS[2] = 28
    if (sYear % 4==0) { MONTH_DAYS[2]++ }
    passed_Jiffies = cbm.RDTIML()
    cbm.SETTIML( sTimer + passed_Jiffies )

    if passed_Jiffies < 216000 {
       NewHours = 0
       Tmp_T = passed_Jiffies
    } else { NewHours = passed_Jiffies / 216000 Tmp_T = (passed_Jiffies - (NewHours * 216000)) as uword }

    if Tmp_T < 3600 {
       NewMinutes = 0
    } else {
      NewMinutes = (Tmp_T/3600 as long) as ubyte
      Tmp_T = Tmp_T - (NewMinutes as long * 3600)
    }

    NewSeconds = (Tmp_T / 60) as ubyte
    Tmp_T = Tmp_T - (NewSeconds as long * 60)
    if Tmp_T > 20 { NewSeconds++ sJiffies=0 } else { sJiffies = sJiffies + Tmp_T as ubyte }

    if sJiffies > 59 { sJiffies=sJiffies-60 NewSeconds++ }

    sSecs = sSecs + NewSeconds
    if sSecs > 59 { sMins++ sSecs = sSecs - 60 }

    sMins = sMins + NewMinutes
    if sMins > 59 { sMins = sMins-60 sHours++ }

    sHours = sHours + NewHours as ubyte
    if sHours > 24 {
       sHours = sHours - 24
       sDay++
       if sWeekDay < 7 { sWeekDay++ } else { sWeekDay=1}
       if sDay > MONTH_DAYS[sMonth] {
          sDay=1
          if sMonth<12 { sMonth++ } else { sMonth=1 sYear++ }
       }
    }
    cx16.clock_set_date_time(mkword(sMonth,sYear),mkword(sHours,sDay),mkword(sSecs,sMins),mkword(sWeekDay,sJiffies))
}


}


