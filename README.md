# Introduction

This repository shows a proof-of-concept of a jPOS.org transaction server running in a Cloud Foundry environment.  It's primary purpose is to capture the minimal steps to get it running, along with the context to adapt this to your own custom JPOS instances.

It's mostly based on the existing jPOS tutorials available at the time of the POC, and doesn't provide a complete or production-ready transaction manager.  Instead, it aims to show that the socket-based communication and file-based configuration aren't a blocker for this kind of deployment.

# What We'll Need

**A jPOS server to push.**  We'll be following along with the official [jPOS tutorials](http://jpos.org/tutorials), so we'll clone the [jPOS-template](https://github.com/jpos/jPOS-template) repository and build/configure that.
```
git clone https://github.com/jpos/jPOS-template.git gateway
cd gateway
rm -fr .git
```
The commands in the rest of the tutorial will assume the jPOS codebase lives in the `gateway` directory in the root of this repo.

**A Cloud Foundry environment with TCP Routing configured.**  jPOS uses persistent socket-based communication between the server and its clients.  Some CF environments default to TCP routing disabled, so you can check if this is available with the following command:
```
➜ cf router-groups
Getting router groups as admin...

name          type
default-tcp   tcp
```
If you see a router group with type `tcp`, you should be set.  If not, you'll need to work with your platform team to [enable TCP Routers in your environment](https://docs.pivotal.io/application-service/2-10/adminguide/enabling-tcp-routing.html).

# Understanding the End Goal

Cloud-native environments like Cloud Foundry are considered _opinionated_, and they require an app to comform to some specific criteria in order to run successfully.  Our goal is the have the application run in a container _somewhere_ in the platform, but we don't really know (or care) where!  In fact, if I make a couple of requests (or several clients make requests), I can't even be sure that it will be handled by the same instance of my app.  If we can get ourselves comfortable with this constraint, it means the platform has the freedom to run, move, and scale the application across it's environment without a human team having to micromanage the details.  This is really powerful, but it means we need to check that the jPOS gateway conforms to a few critical aspects of a [12-factor app](https://12factor.net).

1. [Configuration](https://12factor.net/config) - We need to make sure that the application doesn't depend on specific configuration files in specific places within its environment.  Configuration should be within the application itself or pulled from an external source like environment variables.
1. [Port Binding](https://12factor.net/port-binding) - In a platform managing many layers of network between a client an app, the application can't expect a specific port.  Another app might be using it, or another instance of _our_ app!  We need the platform to tell the app what port to use and have it start up correctly.
1. [Logging](https://12factor.net/logs) - We don't have access to the rolling files or syslog on our app instances anymore.  There isn't just one or two, but potentiall hundreds of instances of many different apps.  Additionally, if an instance fails, we need the platform to quickly self-heal by spinning up a new instance and we might not be able to get access to that old failed instance to view its logs.  We need all of the apps to log to standard out/err and let the platform scoop up and aggregate it all for us somewhere.
1. [Dependencies](https://12factor.net/dependencies) - We need to make sure the application doesn't assume specific installed packages or currated folders of dependencies on the filesystem of its deployment environment.

If we can check those boxes off, we're pretty confident an app can run in a Cloud Foundry environment.  Sure, lots of the other factors will help you run well in a cloud-native environment, but these will usually get you deploying.

We have one additional constraint working with the jPOS gateway - Cloud Foundry's default communication model is HTTP, but jPOS depends on persistent TCP socket connections between clients and the server.

With HTTP endpoints, the platform routes incoming traffic through a special component called the Go Router that knows the URLs for all apps running in the environment.  When a user makes a request for an app, that hits the Go Routers, which can then forward on to the appropriate VM running instances of the app, which in turn can forward on to the appropriate container network to hit a specific instance of the app.  If the user makes a second call to the same HTTP endpoint, the Go Routers might choose a different VM running additional instances, or the VM might choose a different container - horizontal scaling works because the platform spreads the load across running instances.

TCP socket connections are a little different but the flow generally holds true.  Another set of routers called TCP Routers serve a similar function, keeping track of all of the _ports_ exposed by various apps running in the platform.  When a client makes a connection to the TCP router on a specific port, the routers can connect that client to the right VM and the right container instance (all the while mapping between ephemeral ports so that multiple apps can run at the same time).  Unlike the HTTP Routers, the TCP routers will maintain a consistent connection between a client and the specific instance of the application until the connection is closed.  Starting another connection might get you a different VM or container, but you're talking to the same app instance for the life of your connection.

Alright, that's enough backround!  Let's check our handful of critical cloud-native factors and see how we set jPOS with TCP routing on the platform.

# Understand jPOS and the 12 Factors

Let's run through each of our aspects and look through the jPOS codebase to see how things hold up.

## Dependencies

Going through the initial jPOS tutorial, it has you download a distribution of the jPOS gateway that contains the JAR, some startup scripts, and a couple of directoring containing configuration in XML files.  The tutorial itself walks you through adding additional files to the `deploy` directory to configure additional threads to handle listening and responding to transactions, so this feels like the biggest area of interest for config data.

When you push an application to a Cloud Foundry environment, it sends the application bits up to the platform so that it can build a container image using [buildpacks](https://buildpacks.io/).  This is really powerful, because it means developers aren't worrying about patching base images or JDK versions, and the platform handles all of that.  Buildpacks know what to do with different kinds of pushed app bits - for example, the Java buildpack knows how to run JARs and WARs, the NodeJS buildpack knows what to do with a directory containing a `package.json`, and so on.  This means we need to figure out _what_ to push to the platform to get a running instance of jPOS.

The obvious starting point is to push the JAR and see if it works:
```bash
cd gateway

# Build the jPOS-template gateway
./gradlew clean build installApp

# Check that the build looks like the directory distribution from the tutorial
ls -lah build/install/gateway

total 8
drwxr-xr-x   7 mjcampbell  staff   224B Apr  5 10:37 .
drwxr-xr-x   3 mjcampbell  staff    96B Apr  5 10:37 ..
drwxr-xr-x   7 mjcampbell  staff   224B Apr  5 10:37 bin
drwxr-xr-x   4 mjcampbell  staff   128B Apr  5 10:37 deploy
-rw-r--r--   1 mjcampbell  staff   945B Apr  5 10:37 gateway-2.1.6-SNAPSHOT.jar
drwxr-xr-x  20 mjcampbell  staff   640B Apr  5 10:37 lib
drwxr-xr-x   3 mjcampbell  staff    96B Apr  5 10:37 log

# Log into your PCF environment
cf login --skip-ssl-validation -a https://api.sys.millbrae.cf-app.com

# Target the org and space to deploy the app in your environment
cf cf target -o demo -s dev

# Push the app!
cf push -p build/install/gateway/gateway-2.1.6-SNAPSHOT.jar jpos
```

You'll see the app fail to start, and running `cf logs jpos` should show the error:
```
2021-04-05T10:44:46.97-0400 [APP/PROC/WEB/0] ERR Error: Could not find or load main class org.jpos.q2.Q2
```
Interestingly, if we check the contents of that gateway JAR file, we'll see it doesn't have a whole lot inside.  jPOS is expecting all of the dependencies to come from the `lib` directory, and the `Q2` main class is actually in `lib/jpos-2.1.6-SNAPSHOT.jar`.  So we've run up against our first critical factor: _Dependencies_.

I tried a few ways to combine all of these JARs into a single self-running uberjar, including pulling them into a Spring Boot project, using the ShadowJar gradle plugin, and building my own uberjar manually.  All of these failed to run successfully due to the complex MANIFEST.mf file that jPOS builds for it's current setup.

> Note: For a production build, I'd look further into a repeatable and automated packing of the server into an uberjar.

We have another option: we can push the whole directory, including the `lib` directory.  We'll have to do a little bit more explicit configuration of the buildpack since the Java buildpack won't know how to run by default anymore.  It's not a perfect solution, but its useful for working while you refactor an app to be more self-contained.  Let's try it now:

```
cf push -p build/install/gateway jpos
```

If you check the logs again, it should be complaining that it can't find the `java` command:
```
[ERR] /home/vcap/app/bin/q2: 11: exec: java: not found
```

The Java buildpack was smart enough to guess it was responsible for this based on the gradle file or the JAR files, but it's running the include startup script and that isn't built with the buildpack or container in mind.  We can see the startup command that the Java buildpack has inferred in the failed CLI command's response, so we have a few options.  We could update the `q2` startup script to pull the JAVA_OPTS and other automatic configuration in a standard JAR push:
```bash
JAVA_OPTS="-agentpath:$PWD/.java-buildpack/open_jdk_jre/bin/jvmkill-1.16.0_RELEASE=printHeapHistogram=1 -Djava.io.tmpdir=$TMPDIR -XX:ActiveProcessorCount=$(nproc)
                 -Djava.ext.dirs=$PWD/.java-buildpack/container_security_provider:$PWD/.java-buildpack/open_jdk_jre/lib/ext
                 -Djava.security.properties=$PWD/.java-buildpack/java_security/java.security $JAVA_OPTS" &&
                 CALCULATED_MEMORY=$($PWD/.java-buildpack/open_jdk_jre/bin/java-buildpack-memory-calculator-3.13.0_RELEASE -totMemory=$MEMORY_LIMIT -loadedClasses=13197 -poolType=metaspace
                 -stackThreads=250 -vmOptions="$JAVA_OPTS") && echo JVM Memory Configuration: $CALCULATED_MEMORY && JAVA_OPTS="$JAVA_OPTS $CALCULATED_MEMORY" && MALLOC_ARENA_MAX=2 SERVER_PORT=$PORT
                 eval exec $PWD/.java-buildpack/open_jdk_jre/bin/java $JAVA_OPTS -cp $PWD/. org.springframework.boot.loader.JarLauncher
```
We can see it calling the buildpack's bundled Java binary from `$PWD/.java-buildpack/open_jdk_jre/bin/java` and passing in a bunch of computed memory configuration in through `JAVA_OPTS`, but making `q2` do all of this would be a bit invasive for our proof-of-concept.

Instead, we can override the buildpack's `command`.  Let's move to an [application manifest file](https://docs.cloudfoundry.org/devguide/deploy-apps/manifest-attributes.html) instead of specifying the push arguments on the command line.  Create a `manifest.yml` in the root of your repo:
```yaml
---
---
applications:
- name: jpos
  path: build/install/gateway
  buildpacks:
  - java_buildpack_offline
  health-check-type: port
  env:
    JBP_CONFIG_OPEN_JDK_JRE: '{ jre: { version: 11.+ } }'
  command: 'ls -lah $PWD && JAVA_OPTS="-agentpath:$PWD/.java-buildpack/open_jdk_jre/bin/jvmkill-1.16.0_RELEASE=printHeapHistogram=1 -Djava.io.tmpdir=$TMPDIR -XX:ActiveProcessorCount=$(nproc) -Djava.ext.dirs=
    -Djava.security.properties=$PWD/.java-buildpack/java_security/java.security $JAVA_OPTS" && CALCULATED_MEMORY=$($PWD/.java-buildpack/open_jdk_jre/bin/java-buildpack-memory-calculator-3.13.0_RELEASE -totMemory=$MEMORY_LIMIT
    -loadedClasses=14926 -poolType=metaspace -stackThreads=250 -vmOptions="$JAVA_OPTS") && echo JVM Memory Configuration: $CALCULATED_MEMORY && JAVA_OPTS="$JAVA_OPTS $CALCULATED_MEMORY" && MALLOC_ARENA_MAX=2 eval exec
    $PWD/.java-buildpack/open_jdk_jre/bin/java $JAVA_OPTS -cp
    $PWD/lib/.:$PWD/gateway-2.1.6-SNAPSHOT.jar:$PWD/.java-buildpack/client_certificate_mapper/client_certificate_mapper-1.11.0_RELEASE.jar:$PWD/.java-buildpack/container_security_provider/container_security_provider-1.18.0_RELEASE.jar org.jpos.q2.Q2'
```
We can now run `cf push` in our gateway directory without any additional parameters to it'll use this manifest to pull the app name, the path to our pushable build artifact, and anything else configured in the file.

We've made a couple of changes in this manifest:
- We've introduced the `port` health check type to decide if the app started successfully.  It'll check to see if the app instance is listening on the port specified by the `$PORT` environment variable.
- By default, the Java buildpack will deploy using the OpenJRE 8.  I've updated it to run in Java 11 as the most recent LTS-supported version of Java.
- We've customized the standard command for a Java JAR, replacing the `-cp $PWD/.:...` with a classpath build from our pushed directory: `-cp $PWD/lib/.:$PWD/gateway-2.1.6-SNAPSHOT.jar:...`

If we `cf push` with this manifest, we'll see some of the standard jPOS logging and a new error:
```
021-04-05T12:21:22.559-04:00 [HEALTH/0] [ERR] Failed to make TCP connection to port 8080: connection refused
2021-04-05T12:21:22.559-04:00 [CELL/0] [ERR] Failed after 1m1.598s: readiness health check never passed.
```

The app looks like it's starting, but its failing the port health check because there's nothing listening on port 8080!

## Configuration & Port Mapping

The jPOS tutorial walks you through creating a handful of additional XML files in your deploy directory to configure the gateway to respond to connections and messages.  Since we're pushing the distribution as a directory for our dependencies, we're also pushing our deploy directory so we should be able to push these new files too.

Download the [50_xml_server.xml](http://jpos.org/downloads/tutorials/gateway/50_xml_server.xml), [10_channel_jpos.xml](http://jpos.org/downloads/tutorials/gateway/10_channel_jpos.xml), [20_mux_jpos.xml](http://jpos.org/downloads/tutorials/gateway/20_mux_jpos.xml), and [30_txnmgr.xml](http://jpos.org/downloads/tutorials/gateway/30_txnmgr.xml) provided by the jPOS tutorial into your `gateway/src/dist/deploy`.

The file `50_xml_server.xml` has an explicit port 8000 configured, but the platform expects an application to start listening on whatever port is specified on the `PORT` environment variable.  It might be 8000, but it might be something else.  Taking a quick look through the [jpos codebase](https://github.com/jpos/jPOS) for any usage of `System.getenv`, we see that the [Environment class tries to interpolate config in the format `${VARIABLE}`](https://github.com/jpos/jPOS/blob/a4d492423f248a9a582b0344f9701f543b05250a/jpos/src/main/java/org/jpos/core/Environment.java#L106) from environment variables.

Let's change the port `<attr>` in the config file `50_xml_server.xml` to the following:
```xml
<server class="org.jpos.q2.iso.QServer" logger="Q2" name="xml-server-8000" realm="xml-server-8000">
  ...
  <attr name="port" type="java.lang.Integer">${PORT}</attr>
  ...
</server>
```

If we rebuild and push, it starts up!
```bash
./gradlew clean build installApp

cf push
```

## Logging

We're seeing some expected logs coming over standard out/err, so for now we can check this box.  Things to watch out for down the road would be to update the app's configuration to explicitly _not_ log to files to avoid filling up the container's disk quota.

# TCP Routing, Sockets, & Testing Our Deployment

By default, our app got an HTTP route based on our application's name assigned automatically.  You can see the routes assigned to your app in the app metadata:
```bash
# Get metadata for the apps in your currently-targeted space
cf apps
Getting apps in org demo / space dev as admin...

name   requested state   processes           routes
jpos   started           web:1/1, task:0/0   jpos.apps.millbrae.cf-app.com
```

If we go to https://jpos.apps.millbrae.cf-app.com in a browser, we get a bunch of timeouts logged by JPOS because it's expecting XML data coming over the connection and it's getting a bunch of HTTP protocol junk instead!  We need to [give the application a TCP route instead](https://docs.pivotal.io/application-service/2-10/devguide/deploy-apps/routes-domains.html#http-vs-tcp-routes).  A TCP route consists of a TCP domain assigned to the platform and a port.  We can find a TCP domain with the `cf domains` command:
```bash
# List the domains available in the platform
cf domains

Getting domains in org demo as admin...

name                       availability   internal   protocols
apps.internal              shared         true       http
apps.millbrae.cf-app.com   shared                    http
tcp.millbrae.cf-app.com    shared                    tcp
```

We can add the tcp domain as a route without any port and the platform will assign us an unused one, or we can explicitly specify a port in the route:
```yaml
---
applications:
- name: jpos
  path: build/install/gateway
  routes:
  - route: tcp.millbrae.cf-app.com:1024
  ...
```

Let's test this new TCP route with the process described in the jPOS tutorials:
```bash
# Use netcat to connect to our app using the TCP domain and port number
nc tcp.millbrae.cf-app.com 1024

# Paste in the default request
<isomsg>
   <field id="0" value="0800" />
   <field id="11" value="000001" />
   <field id="41" value="00000001" />
   <field id="70" value="301" />
</isomsg>
```

You should see a response from the server:
```
<isomsg>
  <!-- org.jpos.iso.packager.XMLPackager -->
  <field id="0" value="0810"/>
  <field id="11" value="000001"/>
  <field id="37" value="718906"/>
  <field id="38" value="613163"/>
  <field id="39" value="00"/>
  <field id="41" value="00000001"/>
  <field id="70" value="301"/>
</isomsg>
```
If you check your app logs with `cf logs jpos --recent`, you should see the server-side response logging there as well.

If you make another connection and send more messages, you'll see that the logs have a `web/0` label that shows they're being handled by the same instance with that name.  Let's scale the app and see how things work:
```bash
# Scale the app to three instances
cf scale jpos -i 3
```

# The Recipe

Here's the complete list of changes we had to run through in order to get jPOS running on Cloud Foundry:

TODO