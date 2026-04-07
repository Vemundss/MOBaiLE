from __future__ import annotations

import os
import subprocess
from datetime import datetime
from subprocess import CompletedProcess

from app.models.schemas import AgendaItem


class CalendarService:
    def fetch_today_events(self) -> list[AgendaItem]:
        if os.uname().sysname.lower() != "darwin":
            raise RuntimeError("calendar adapter currently supports macOS only")

        proc = subprocess.run(
            ["osascript", "-e", self._calendar_script()],
            capture_output=True,
            text=True,
            timeout=20,
        )
        if proc.returncode != 0:
            stderr = proc.stderr.strip() or "unknown osascript error"
            raise RuntimeError(stderr)
        return self._parse_event_rows(proc)

    @staticmethod
    def _parse_event_rows(proc: CompletedProcess[str]) -> list[AgendaItem]:
        items: list[AgendaItem] = []
        for line in proc.stdout.splitlines():
            parts = line.split("\t")
            if len(parts) < 4:
                continue
            start, end, title, calendar = parts[0], parts[1], parts[2], parts[3]
            location = parts[4] if len(parts) > 4 and parts[4].strip() else None
            if location and location.strip().lower() == "missing value":
                location = None
            items.append(
                AgendaItem(
                    start=start.strip(),
                    end=end.strip(),
                    title=title.strip() or "(Untitled)",
                    calendar=calendar.strip() or "Calendar",
                    location=location.strip() if location else None,
                )
            )
        items.sort(key=lambda item: (item.start, item.end, item.title))
        return items

    @staticmethod
    def today_label() -> str:
        return datetime.now().strftime("%A, %B %d, %Y")

    @staticmethod
    def _calendar_script() -> str:
        return r'''
set nowDate to current date
set y to year of nowDate
set m to month of nowDate
set d to day of nowDate
set startDate to date ("00:00:00 " & (m as string) & " " & d & ", " & y)
set endDate to startDate + (24 * hours)
set rows to {}
tell application "Calendar"
    repeat with cal in calendars
        set calName to name of cal
        set evs to (every event of cal whose start date < endDate and end date > startDate)
        repeat with ev in evs
            set s to start date of ev
            set e to end date of ev
            set titleText to summary of ev
            set locText to ""
            try
                set locText to location of ev
            end try
            set sh to text -2 thru -1 of ("0" & (hours of s as string))
            set sm to text -2 thru -1 of ("0" & (minutes of s as string))
            set eh to text -2 thru -1 of ("0" & (hours of e as string))
            set em to text -2 thru -1 of ("0" & (minutes of e as string))
            set lineText to (sh & ":" & sm & tab & eh & ":" & em & tab & titleText & tab & calName & tab & locText)
            copy lineText to end of rows
        end repeat
    end repeat
end tell
set AppleScript's text item delimiters to linefeed
return rows as text
'''
