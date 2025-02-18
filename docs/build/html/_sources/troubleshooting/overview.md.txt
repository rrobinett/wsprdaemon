# Troubleshooting wsprdaemon

Nothing ever goes wrong!

## Use tmux or screen

Especially useful in managing a computer remotely.  This will enable you to maintain a session between logins or should your network connection drop.

## Use btop!

![](../_images/btop.png)

## Use wdln

This displays the wsprnet upload log.

## Use wdle

## Check recordings

Change to the temporary directory.

```
cdt
```
Then enter the sub-directory for a receiver and channel, for instance, the following moves to receiver KA9Q_0 and a 20m wspr channel:
```
cd recording.d/KA9Q_0/20/
```
Here, you can invoke the wdww alias that dynamically lists the wav files for that channel.  A problem exists if you don't see regular increments of the latest file.

```
wdww
```