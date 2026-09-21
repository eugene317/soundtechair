# Privacy Policy

**Last updated:** August 15, 2026

This is the privacy policy for SoundTech Air (the "app"), a self-hosted controller for Bose SoundTouch speakers on your local network. It's a small utility app, and this policy is deliberately short to match.

## The short version

This app does not collect, sell, or share your personal data. It has no account or login system, no advertising, and no analytics. The only places any data ever goes are: your own speaker (over your local WiFi), and TuneIn's public radio directory when you search for a station. Both are described in detail below.

## The three things this app actually sends or accesses

### 1. Location permission - used only to list nearby WiFi networks

When setting up a new or factory-reset speaker, the app can show you a list of nearby WiFi network names so you can pick your home network instead of typing it in by hand. Android requires the Location permission (`ACCESS_FINE_LOCATION`) before **any** app can read WiFi scan results - this is a platform-wide restriction Android imposes on all apps, not a choice this app makes, because WiFi scan data could theoretically be used to estimate physical location.

This app does not use the permission for that purpose. Your location is **never recorded, stored, logged, or transmitted anywhere** - not by this app, and not to any third party. It's used only, in the moment, to populate the network-name picker during speaker setup. If you'd rather not grant it, you can decline and type your WiFi network name in manually instead.

### 2. Your home WiFi name and password - sent only to your own speaker

During speaker setup, you enter your home WiFi network's name and password into the app. That information is sent directly, over your local network, **only to your own physical speaker** - specifically to the temporary setup WiFi access point the speaker broadcasts while it has no home network configured yet, which your phone connects to briefly during setup.

It is **never sent to any server run by this app's developer, and never to any other third party.** Once your speaker confirms it has joined your home network, this app has no further use for that password and does not retain it for its own purposes.

### 3. Radio station search - sent to TuneIn

If you use the app's radio station search, whatever text you type is sent to **TuneIn** (`opml.radiotime.com`), a third-party public radio-directory service, so it can look up matching stations. TuneIn is an independent company, not affiliated with or operated by this app's developer.

This only happens when you actively search for a station. TuneIn's handling of that request is governed by TuneIn's own privacy policy, not this one.

## What this app does not do

- No advertising SDKs.
- No analytics or tracking SDKs of any kind.
- No account, sign-in, or login system - there is nothing to create an account for.
- No sale of data to anyone, for any reason - there is no data collected that could be sold.
- No data sharing beyond the two flows above (your own speaker, and TuneIn when you search).

## Other permissions

The app also requests a few other standard Android permissions needed to work on your local network and play audio (e.g. WiFi/network state, notifications for media playback controls). None of these are used to collect or transmit personal data beyond what's described above.

## Local storage

A few small settings and your speaker's name/IP address are saved on your own device (using standard Android app storage) so the app can reconnect without rescanning every time. This data stays on your device - it is not uploaded anywhere.

## Changes to this policy

If what this app does with data ever changes, this document will be updated to reflect that, and the "Last updated" date above will change too.

## Contact

Questions about this policy can be sent to: **eugene@airstaffs.com**
