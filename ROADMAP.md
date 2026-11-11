# Busters roadmap

What's planned for Busters, roughly in order. Done items move to the bottom.

## Next up

Adoption plan: meet people where they already are (Discord) and remove work before asking anyone to change. Keep the sheet working so nobody is forced over. Make the app the upgrade, not a requirement.

- **Discord posts (first).** Built Nov 10. Busters posts as its own Discord bot (Bill's role can add bots but not make webhooks); set up on the Team tab with the bot token and a channel ID. Later the bot can read photo replies, answer slash commands like /events, and DM people. Next: add "or see it all in Busters" lines once people start using it, and swap the photo call's "reply here" for Jeff's Dropbox link when that's built.
- **Jeff's event media drop (first win).** Jeff Gritton collects event photos and videos in his Dropbox and said yes to automating it. Plan: Jeff connects his Dropbox to Busters once; for each event Busters makes a folder named date first, like "2026-11-29 Hollywood Christmas Parade", plus a Dropbox file request link (no Dropbox account needed to upload). When the event ends, everyone who went gets the link (Discord post and alert), and the event page gets an Upload photos button. Files go straight to Jeff's Dropbox, never stored by Busters; he syncs them to his computer and moves them to his drive. Setup needs a free Dropbox app in the App Console (https://www.dropbox.com/developers/apps); the private key lives only in the database. Check Jeff's Dropbox has room for video.
- **Event photos and videos in the app.** After Jeff's Dropbox drop is working: an easy way for any Buster to add photos and videos from an event, straight from their phone, sorted automatically into that event's own album. Each event brief gets a Photos section; a crew-wide gallery groups everything by event and date. Ideas: upload many at once, big videos resumed if the signal drops, tags for who's in a shot, a "share with socials" pick list for the person running Instagram, and a download-all for an event.
- **Check-in attendance.** Mark who actually showed up, so event counts, the yearly minimum and fundraising credit go to who worked it, not just who said Going.
- **Saved spots you can retire.** Reusable venues and parking spots that editors can archive when they're no longer used. Also clean up saved place names that have an event name baked in.
- **Chat**, with Discord as a switch inside it.

## Small ideas

- Fixed dues statuses for Personnel (Paid, Paid early, Exempt, Extension, Unpaid).
- Honorary members skip the adoption count and the yearly minimum.
- Show vehicles on events (Ecto cars, the Chief).
- Confirm LAGB's real yearly minimum (Busters assumes 2 events).

## Later

- Logo and app icon (paused; Round 3 "gear" directions are on the logo canvas).
- Other franchises as their own crews.
- Sheet write-back, someday: let the bridge add and remove app sign-ups on the Master Events List. Not now: the bridge stays read-only and nothing on the sheet changes until the sheet's owner OKs edit access.
- Or retire the Master Events List: once LAGB runs sign-ups in Busters, stop the sheet sync.

## Done

- Google bridge: LAGB Calendar Ops every 5 minutes, Master Events List every hour.
- Live Ghostbusters Give Back tracker (hourly), goal, last drive's total and end date (June 1, 2027).
- Alerts: short-staffed events (each person picks days ahead) and the 48-hour last call.
- Fundraising credit per event, hosted-event split, admin-published leaderboard.
- Home with events, answer-on-the-tile buttons, yearly minimum pips, adoption card on Team.
- Members map: LAGB's Google My Maps on the Crew tab with Open in Google Maps; Busters' own city map as a fallback.
- Event page in Google Calendar style; several labeled places per event, each with navigate; call and text buttons for contacts.
- Members can choose to share their phone number.
- Events moved onto Home; answers collapse to one bar once chosen; crew list in two columns.
- Rideshare options removed for now.
- Action log records sign-ins, sign-outs and answers given in the app (from Nov 10).
- Discord posts: short-staffed nudges (1 to 14 days ahead), a photo call the day after each event (thanking who worked it), and a Post to Discord button on event pages. 9am to 9pm only, once per event, no @everyone pings. Bot token kept only in the database.
- Action log filters: All, Changes, Answers, Sign-ins.
- Profiles: info first (events this year, coming up, raised, phone if shared, city, upcoming events); abilities behind an admin-only pencil.
