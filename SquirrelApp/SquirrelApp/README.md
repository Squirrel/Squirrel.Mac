
************
SquirrelApp
************

writes the RELEASES file used for cdn based updates. It can write text based and json based files.

A text based file contains lines like this:
1.0.1 my-release-1.0.1.zip 1499783424

A json based file looks like this:
{
  "currentRelease" : "1.0.1",
  "releases" : [
    {
      "version" : "1.0.1",
      "updateTo" : {
        "pub_date" : "2017-03-09T15:24:55-05:00",
        "notes" : "latest release, everything got better",
        "name" : my-release-1.0.1",
        "url" : "http:\/\/foo\/\/my-release-1.0.1.zip",
        "version" : "1.0.1"
      }
    }
  ]
}


Usage:
./SquirrelApp -releasify -version 1.0 -remote-path http://remote.path/ -notes \"new release\" -file abc.zip -release-file [-force-overwrite YES|NO] -simple-text YES|NO RELEASES.json

