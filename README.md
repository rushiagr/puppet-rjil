[![Build Status](https://travis-ci.org/JioCloud/puppet-rjil.svg?branch=master)](https://travis-ci.org/JioCloud/puppet-rjil)

puppet-rjil
===========

### Table of Contents

1. [Overview - What is puppet-rjil module?](#overview)
2. [Details - how does it work?](#details)
3. [Orchestration - how cross host dependencies work](#cross-host-dependencies)
4. [Development Workflow](#development-environment)
5. [Build script - command line tool for generating test deployments](#build-script)

# Overview

This project is the top level project where most of the deployment coding
for jiocloud happens.

At a high level, it contains the following files/directories

* ./manifests/
  composition Puppet manifests for building jiocloud
* hiera/hiera.yaml
  hiera configuration file that should be used for jiocloud
* hiera/data/
  directory where default hiera data should go. Pretty much anything that
  doesn't contain lookups or secrets should be stored here.
* Vagrantfile
  A Vagrantfile that can be used for faster deployments and iterative
  development.
  NOTE: Vagrant has it's own hiera env data in `./hiera/data/env/vagrant.yaml`:
* Puppetfile
  List of all puppet modules that need to be installed as dependencies.
* ./build\_scripts/deploy.sh - Script that performs deployment of jiocloud.
* ./files/maybe-upgrade.sh - script that actually runs Puppet to perform
  deployments on provisioned machines (when not using vagrant)
* ./environment/full.yaml - contains the defintion of nodes that can be used for testing

# Details

## Building custom deployments

In general, most people be using the predefined full layout for deployments
(which deploys the jiocloud reference architecture for openstack)

This deployment module was built using the following steps:

1. Describe the environment you need to deploy (what roles and how many)

2. Ensure that Puppet configuration exists to support this deployment

3. Ensure the relevant hiera data exists in the hierarchy

4. Use either the build script (deploy.sh) or vagrant to perform an environment build

5. Debug the build process to follow a build's progress

## Layout (stack) data

The build script is driven by a set of data that describes the machines that
need to be configured.

These build scripts can be found in the environment directory.
The filename should be of the form:

````
./environment/<layout>.yaml
````

NOTE: layout actually defaults to env if not specified

where layout/env is an argument passed into the build script/Vagrantfile.

The following file contains our reference architecture for openstack:

````
./environment/cloud.dan.yaml
````

### file contents

This file should contain the top level key `resources`.

Here resources should be listed. Where the names of these
resource should match a node expression.

For example, if the following resources are specified:

````
resources:
  etcd:
    number: 1
    ...
  apache:
    number: 2
```

It will result in hostnames that are prefixed with the following strings:
* etcd1
* apache1
* apache2

## Puppet

### overview

Puppet is responsible for ensuring that each of the defined hosts in our
layout get assigned their correct role.

For example, for the case of an apache server. Puppet contains the description
of how a machine is traisitions to its desired role.

````
+----------+      +-----------+
|  base    |      | configured|
|  image   +------> apache    |
|          |      | server    |
|          |      |           |
+----------+      +-----------+
````

### assigning roles

The provisioned hosts have their hostname set as:

````
<role><number>_<project_id>
````

A set of matching nodes from *site.pp* might look like:

````
node /^etcd\d+/ {

}
node /^apache\d+/ {

}
````

Those nodes definitions should inculde whatever classes are required to configure those
roles.

### external modules

All services that Puppet configures are configured through modules that are installed as
external dependencies to the puppet-rjil module.

These dependencies are defined in the Puppetfile (which results to modules that are installed
using librarian-puppet-simple)

### puppet-rjil as a module

The Puppet-rjil module contains all of the composition roles that we use to compose our dependent
modules into the actual roles defined in site.pp

TODO: document more about the kinds of things that belong here and our expectations for how those
things are developed.

### Populating hiera data

All external data used to customize the depoyment scripts written in Puppet is passed via hiera. This includes all
configuration that is specific to each environment and the reference architecture for jiocloud. You could
realistically say that the combination of the

Understanding hiera is a requirement for using this system. Please get started [here](https://docs.puppetlabs.com/hiera/1/).

# Cross host dependencies

This document is intended to capture the orchestration requirements for our current Openstack installation.

There are two main motivations for writing this document:

1. Our overall orchestration workflow is getting very complicated. It makes sense to document it to ensure
that anyone from the team can understand how it works.

2. The workflow is complicated and not as well performing as it could be. This document is intended to
capture those issues along with recommendations for how it can be improved.

## Configuration Orchestration

### Consul

Orchestration is currently managed by both consul and etcd (although in the future, we will be eliminating
etcd in favor of consul for everything)

Consul works as follows:

  * The following Puppet Defined resource `rjil::jiocloud::consul::service` is used to define a service in consul.
  * Each service registers its ip address as an A record for the address: `<service_name>.service.consul`
  * Each service registers its hostname: `<hostname>.node.consul` and registers that as a SRV record for `<service_name>.service.consul`

#### using DNS

Each agent uses DNS to understand what services are available. There are two ways in which Puppet needs to interact with DNS.

1. block until an address is resolvable
2. block until we can retrieve registered A records or SRV records from an address.

#### Puppet design and implications

##### Puppet design

Due to the design of Puppet, these two use cases are implemented in ways that are fundamentally different. The reason that these
two cases are different is due to the distinction in Puppet between compile time versus run time actions.

1. compile time - Puppet goes through a separate process of compiling the catalog that will be used to apply the
   desired configuration state of each agent. During compile time, the following things occur:

* classes are evaluated
* hiera variables are bound
* conditional logic is evaluated
* functions are run
* variables are assigned to resource attributes

This phase processes Puppet manifests, functions, and hiera.

2. run time - during Run time, a graph of resources is applied to the system. Most of the logic that is performed
   during these steps is contained within the actual ruby providers.

##### Puppet orchestration integration tooling

We have implemented the following tools to be used in combination with consul.
  * rjil::service\_blocker - a type that blocks until an A record is registered for an address. It is configured to tell it
    now many times to retry and how long to sleep between each attempt. This check is performed at run-time and requires that
    the hostname to lookup is known ahead of time and that only that hostname is being used to determine attribute values for
    a resource.
  * service\_discovery\_dns - A function that performs a DNS SRV lookup, and returns either discovered ips, hostname, or a hash
    or both. This method is used in cases where information used to populate resource attributes needs to be determined
    dynamically.

##### Implications

The way that Puppet is designed has several implications to the design of our system. In order to achieve the
best performance, it is better to block during resource execution (and run-time) because you can set dependencies
on which resources can be applied in parallel by indicating those resources should be applied before the service\_blocker.
This means that many more resources can be applied in parallel. For example, it would be easy to  use Puppet
dependencies to ensure that the service blocker never happened before any packages are installed.

However, since variable substitution occurs during compile time, anything that relies on using the static DNS address,
(ie: by using the service\_discovery\_dns function) must be performed during compile time. This means that the entire
catalog application is blocked until this data becomes available.

## Openstack Dependencies

This section is intended to document all of the cross host dependencies of our current Openstack architecture,
and emphasize the performance implications of each step.

1. All machines block for the etcd/consul server to come up.

2. Currently, the stmonleader, contrail controller, and haproxy machine can all start applying configuration immediately.

** The contrail node can currently install itself successfully as soon as consul it up. This is only because it doesn't
   actually install the service correctly.

** stmonleader can install itself as soon as consul is ready. It may have to run twice to configure OSD's (which we may do
   in testing, but not in prod)

** haproxy - can install itself, but it does not configure the balance members until the controller nodes are running.


It is worth noting that two of these roles will need to reapply configuration when the rest of the services come online.

* haproxy needs all addresses for all controllers it adds them as pool members
* stmonleader needs to have all it's mons registered as well as an OSD number that matches num replicas.

3. Once stmon.service.consul is registered in consul, stmon, ocdb, and oc can start compiling. These machines have
   not performed any configuration at all at this point. At the same time, stmonleader might be adding it's osd (which
   takes two runs)

4. oc will start compiling, but it blocks until the database is resolvable, once that is resolvable, it continues. At the same
  time stmon's are rerunning Puppet to set up their osd drives.

5. once oc and ocdb are up, haproxy registers poolmembers.

#### Diagram

The below diagram is intended to keep track of what services are dependent on other services
for configuration.

                  +--------+
                  | consul |
                  +------+-+---------------+--------------+
                         |                 |              |
                         |                 |              |
                         |                 |              |
                         |                 |              |
                 +-------v-----+     +-----v----+   +-----v----+
                 | stmonleader |     | contrail |   |  haproxy |
            +----+-----------+-+     +----------+   +----------+
            |                |
            |                |
            |                |
        +---v---+        +---v--+
        | stmon |        | ocdb |
        +-------+        +----+-+
        |                     |
        |                     |
        |                     |
    +---v---+               +-v--+
    | stmon |               | oc |
    +-------+               +----+-----+
                                       |
                                       |
                                       |
                                       |
                                  +----v----+
                                  | haproxy |
                                  +---------+


### known issues

1. the system still does not properly distinguish between addresses of services that will be running vs.
   addresses of things that will be running.

For example: glance, cannot actually be a functional service until keystone has been been registered as
a service and it's address propagated to the load balancer. However, the load balancer cannot be properly
verified until glance has registered (maybe this is actually not a problem...)

2. We have not yet implemented service watching. Currently, it is possible that all occurrences of a certain
   service are not property configured. This is because Puppet just continues to run until it can validate a
   service as functional. The correct way to resolve this is to ensure that you can watch a service, and ensure
   that Puppet runs to reconfigure things when service addresses change (this would currently apply to zeromq,
   ceph, and haproxy.)

3. Failing on compile time adds significant wall-clock time to tests, especially because multiple nodes have to
   be installed completely in serial.

4. The system doesn't really know when it is done running Puppet. We need to somehow understand what the desired
   cardinality is for a service. Perhaps this should be configured as a validation check (ie: haproxy is only
   validated when it has the same number of members as there should be configured services.)

# Development environment

## Installing vagrant

[Install Virtualbox](http://www.virtualbox.org/manual/ch01.html#intro-installing)

It is possible that you can use lxc for this, but it is not fully validating.

[Install vagrant](https://docs.vagrantup.com/v2/installation/)

This setup has been tested with the 1.6.5 installer from [Vagrant Home Page](https://www.vagrantup.com/downloads.html)
The default version of Vagrant in the Ubuntu 14.04 Repo is 1.4.3 which causes an [issue](https://github.com/mitchellh/vagrant/pull/3349).

## Using vagrant

Vagrant makes it easier to perform iterative development on modules.

It allows you to develop on your local laptop and see the effects of those changes
on localized VMs in real time.

We have designed a vagrant based solution that can be used to create VMs that
very closely resemble the openstack environments that we are deploying.

When spinning up VMs for local development, Vagrant/VBox would need to be run on the physical host that has VT-x  enabled in its BIOS. Currently, this setup cannot be provisioned and tested inside a VM itself (KVM/VBox).

### getting setup

The following initial setup steps are required to use the vagrant environment:

* clone project:

````
git clone git://github.com/jiocloud/puppet-rjil
````

* setup tokens (this is required for setting up consul and etcd)
NOTE: etcd is currently required to do anything related to provisioning openstack, so you
need to generate usique tokens per environment. It is possilbe that this requirement will
eventually go away, but for now it is a requirement.

````
source newtokens.sh
````

* install puppet modules

First, you need to make sure that your Puppet module dependencies are
installed:

NOTE: make sure that you install librarian-puppet-simple and *not* librian-puppet!!!!
NOTE: If you are behind a firewall which doesn't allow git protocol, do `export git_protocol=https` in the current shell.

````
gem install librarian-puppet-simple
# from root level of this repo
librarian-puppet install
````

* create rjil directory in modules
This step is required b/c the top level directory (ie: puppet-rjil is a module itself and
it needs to exist in the modulepath for the vagrant environment.

````
mkdir modules/rjil
````

* setup your extra environment variables

The Vagrantfile accepts a few additional environment variables that can be used to further customize the environment.

````
# used to set a local system squid proxy (recomended!!!)
export http\_proxy=http://10.22.3.1:3128
export https\_proxy=http://10.22.3.1:3128
# used to customize the environement to use
export env=vagrant-lxc
````

### vagrant operations

Once you have initialized your vagrant environment using the above steps, you are ready to start using vagrant.

It is highly recommended that if you intend to use this utility that you be famliar with the basics of
[vagrant](https://www.vagrantup.com/).

#### vagrant status

To get a list of support roles that can be booted by vagrant, run:

````
vagrant status
````

This list is populated using the ./environment/full.yaml file by default. It is possible to
customize the roles to be populated by adjusting

#### vagrant up

To boot your desired role in vagrant
````
vagrant up <role>
````

#### vagrant provision

To re-run Puppet provisioning (for interactive development of modules):

````
vagrant provision <role>
````

#### vagrant ssh

To login to VMs:

````
vagrant ssh <role_name>
````

### using vagrant to spin up dev machines:

## Adding new roles to vagrant

1. Ensure that the role exists in site.pp as a node declaration

````
node /^somerole/ {
  include somerole
}
````

2. Ensure the node is defined in Vagrant

Roles in vagrant are populated from layouts. In order to be able to see
a machine in vagrant, you need to add it to environment/layout.yaml
for your custom layout or for the layout you are working on.

Then you need to set the layout env variable.

3. Add relevant hiera data. Vagrant environment specific data should
be added to the following location.

````
./hiera/data/env/<env_name>.yaml
````

# Build script

This project contains the following script that is used to deploy out openstack
environments.

````
build\_scripts/deploy.sh
````
## build script environment variables

The script can be configured using the following environment variables:

## BUILD\_NUMBER (required)

Used to attach a unique identifier to all vms created as a part of a test deployment.
This is useful for distinguishing between separate sets of machines that may be
on the same network.

If you are going to be performing multiple deployments for testing purposes, it is recommended
to use a timestamp to make the build number unique per invocation:

````
export BUILD\_NUMBER=`date +"%d%m%y%H%M%S"`;
````

This build number is appended to all of the hostname prefixes of the provisioned machines.

### env (required)

The environment indicator.

````
export env=dan
````

This is used to determine the file that specifies what machines
should exist for a specific deployment.
It refers to the file environment/cloud.${env}.yaml.

It is also used to pull env specific hiera data from ./hiera/data/env/${env}.yaml

### KEY\_NAME (required)

The name of the keypair that will used assigned to the VM.

````
export KEY\_NAME=openstack\_ssh\_key
````

### env\_file (optional)

File that contains the following environment variables used to configuration access
and authentication against your openstack environment.

This argument is optional provided that you manually provide those environment variables.

````
export env\_file=~/credentials.sh
````

### timeout (optional)

Name of the command that provides the timeout capability. You should only even have to
set this if you are using the script from a Mac (or other Unix system).

````
export timeout\_command=gtimeout
````

### puppet\_modules\_source (optional)

Location of source repository for puppet-rjil. This is required if you want to test against
a branch instead of against the puppet-rjil contents that are packaged. This is very
handy for pre-validating some configuration before running tests.

````
export puppet\_modules\_source\_repo=https://github.com/bodepd/puppet-rjil
````

### puppet\_modules\_source\_branch (optional, only makes sense together with puppet\_modules\_source)

Branch that should be used from the provided puppet-rjil repo.

````
export puppet\_modules\_source\_branch=origin/deploy\_script
````

### ssh\_user

User to that build process should use to ssh into etcd server.

````
ssh\_user=ubuntu
````

### git_protocol (optional)

Protocol to use when fetching puppet modules. Defaults to `git`.

````
export git_protocol=https
````

## Example of a full invocation

This is what I used for testing:

````
export BUILD\_NUMBER=test\_`date +"%d%m%y%H%M%S"`;export env=dan;export KEY\_NAME=openstack\_ssh\_key; export env\_file=~/credentials.sh;export timeout\_command=gtimeout; export puppet\_modules\_source\_repo=https://github.com/bodepd/puppet-rjil;export puppet\_modules\_source\_branch=origin/deploy\_script;export ssh\_user=ubuntu;bash -x build\_scripts/deploy.sh
````

## dependencies on mac

The first time this script runs (or when it needs to update the version of jiocloud
install), there are a few deps that need to be manually installed on Mac.

````
brew install python
pip install virtualenv
brew install libffi
brew install libyaml
brew install coreutils
alias timeout=gtimeout
````


It is possible that you will also have to manually update the include path to ensure
that libffi is available:

````
export CFLAGS="-I/usr/local/opt/libffi/lib/libffi-3.0.13/include/"
````

# TODO

## supporting devs

we want to better support project devs.

here is what I envision:

  - developers can check out their local code into the puppet-rjil environment
  - set it up as a mount in vagrant (or rely on the fact it will be automaounted into /vagrant/)
  - customize the load path for whatever is using it
