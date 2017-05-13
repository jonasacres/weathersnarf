# Introduction
This is something I wrote to snarf data off of an AcuRite smartHUB. It's not the most elegant or portable solution, but it works. I'm throwing it up on Github, because this is just where I go to store code! I'm gonna write this README to be helpful to someone who is totally clueless about how to solve this problem -- which is probably going to be me, in 18 months, when I replace my router or my pi and need to fix my weather setup.

# Motivation
AcuRite puts out a 5-in-1 weather monitoring system (found here: https://www.acurite.com/weather-environment-system-900wes.html). Basically, you put one of these in your yard or on your roof or something, and it measures temperature, barometric pressure, humidity, rainfall and wind. The sensor continuously radios its readings down to monitors.

They have these cool little LCD screens that you can put in your house, but they also have this smartHUB system that is pretty much just a radio receiver with an ethernet jack on it. The smartHUB automatically picks up any AcuRite sensors in range, and when they report in, it uploads the data to AcuRite's servers. Unfortunately, while AcuRite does offer a way to upload sensor data to Weather Underground as of the time of this writing (May 2017), there doesn't seem to be a way to download the data for your own use. I really wanted to keep weather data in my own database so that I can use it for my own stuff, and have a historical record if AcuRite ever stops offering this service.

# Environment

* Sensor: AcuRite 5-in-1 weather sensor, purchased May 2017.
* smartHUB: AcuRite smartHUB, model 09150M.
* Raspberry Pi: Pi 2 Model B running Raspbian 7.8.
* Router: Netgear R7000 running DD-WRT v24-sp2 K3 kongac, Build 25100M

# How it works
The smartHUB seems to just relay sensor data to AcuRite's servers every 15-30 seconds. This is done through an unencrypted HTTP GET request to http://hubapi.myacurite.com/weatherstation/updateweatherstation, with a query string that has all the sensor data. Not all sensor data is present in each update. Sometimes, certain data fields are omitted, for reasons that aren't immediately clear to me.

Key | Type | Value
--- | ---- | -----
action | string | Always seems to be "updateraw" in all the events I've seen
realtime | integer | Always seems to be "1" in all the events I've seen
rtfreq | integer| No idea what this is. Mine always reads "36", and my neighbor's unit always seems to omit this field.
id | string | Appears to be a unique ID for the smartHUB unit
mt | string | Mine always says "5N1x31". I'm guessing this is a model number.
sensor | string | Formatted as zero-padded 8-digit decimal number (based on sample size of 2 sensors). Appears to be unique ID for each AcuRite sensor.
windspeedmph | integer | Wind speed, in miles per hour
winddir | integer | Wind direction, in degrees. (TODO: relative to what direction? is positive clockwise or counterclockwise?)
rainin | real | Recent rainfall, in inches. I'm not clear on when this resets back to 0.
dailyrainin | real | Recent rainfall, in inches. Appears to reset to 0 daily.
baromin | real | Barometic pressure, in inches of mercury
tempf | real | Temperature, in degrees fahrenheit. Measures to 1/10th degree.
humidity | integer | Humidity, in percentage points
dewptf | integer | Dew point, in degrees fahrenheit
rssi | integer | Appears to be signal strength. The sensor on the roof of my house reads "2". The sensor on my neighbor's house reads "1".
battery | string | Appears to be battery status. Mine says "normal". Not sure what it says when the battery goes bad.

The way this solution grabs data is by using tcpdump on my wireless router, and piping it via netcat to a Raspberry Pi, which parses the tcpdump output, gets the query string data, and logs it to an sqlite3 database.

# Router portion

I use my router to get access to the smartHUB data. I've flashed it with DD-WRT so I can ssh into it and run commands. This included tcpdump and netcat, so I use those to listen for web traffic from my smartHUB at 10.0.1.115, dump the traffic to STDOUT, and forward it via netcat to the weathersnarf.rb process on my Raspberry Pi at 10.0.1.116 on port 10100.

```
tcpdump -X host 10.0.1.115 and port 80 | nc 10.0.1.116 10100
```

To make that run automatically when the router comes up, and retry if the Raspberry Pi stops listening for some reason, use `weathersnarf-router.sh`. In my setup, I put it in `/jffs/jonas/weathersnarf-router.sh`. I had to turn on JFFS2 Support in the Administration section of the DD-WRT web config to get /jffs mounted. This lets us store the script in NVRAM so it doesn't get wiped out when the router loses power.

Put `weathersnarf-router.startup` in `/jffs/etc/config`. You'll need to edit the script to change the environment variables at the top to reflect your exact setup. `/jffs/etc/config` contains scripts to be run automatically by DD-WRT on startup. I'm mildly concerned that there's nothing restarting the process if it dies, but weathersnarf-router.sh is a pretty simple shell script in an infinite loop, so I'm not that worried about it.

Once you install it, you can either restart the router, or manually run `/jffs/etc/config/weathersnarf-router.startup`.

# Raspberry Pi portion

The Pi just runs weathersnarf.rb to listen for incoming connections on port 10100. This is not a beautiful piece of code, and frankly, it could be done a lot better. But you know what? It's working, and that's enough for me for now! :)

pi/weathersnarf.rb needs ruby and sqlite3 (with the sqlite3 gem) to work. I did this to get those on Raspbian 7.8:

```
sudo apt-get update
sudo apt-get install sqlite3 libsqlite3-dev ruby ruby-dev
sudo gem install sqlite3
```

Either comment out this line in `weathersnarf.rb`, or change it to an http-keystore that is valid on your network:

```
$http_keystore_url = "http://10.0.1.125:11000"
```

http-keystore is a dead simple ruby script for storing key-value pairs. I'm using it here so I can make widgets that pull my latest weather data. If you do

```
GET http://10.0.1.125:11000/sensor-12345678
```

you'll get a JSON string with the latest weather data from the sensor whose ID is 12345678.

## Autostart with sysvinit scripts
I wanted pi/weathersnarf.rb to run on system start, so I wrote an init.d script for it (pi/weathersnarf). On Raspbian 7.8, I put pi/weathersnarf in /etc/init.d, and ran this as root:

```
adduser weather
update-rc.d weathersnarf defaults
service weathersnarf start
```

then I put pi/weathersnarf.rb into ~weather.

## Autostart with systemd
And then the next day I decided to upgrade my pi to Jessie, which meant now I need to use a systemd script. I did this to get it going:

```
as root:
adduser weather
su - weather
git clone https://github.com/jonasacres/weathersnarf
logout

cp ~weather/weathersnarf/pi/weathersnarf.service /etc/systemd/system
systemctl start weathersnarf
systemctl enable weathersnarf.service
```

And that's it. Now there should be a steadily-growing sqlite3 database in ~weather/weather.db.

I added a cronjob to upload this to my NAS regularly. At some point, I'll probably add something to rotate the database file, since otherwise it will grow boundlessly and eventually fill up the Pi's SD card.

# Database

The database is in ~weather/weather.db, and has a table called "weather". It has columns for each of the fields in the hubapi.myacurite.com query string that I considered to be most significant (sensor, windspeedmph, winddir, rainin, dailyrainin, humidity, tempf, dewptf, baromin), along with a few more for bookkeeping:

Key | Type | Value
--- | ---- | -----
record_id | integer | autoincrement primary key
time_inserted_epoch | integer | time record was inserted into db, in seconds since 1/1/1970 00:00:00 +0000
time_inserted_str | string | time record was inserted into db, as YYYY-MM-DD HH:MM:SS +ZZZZ localtime
query | string | raw query string sent to AcuRite server, containing all original data

