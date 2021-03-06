###########################################
package Pogo::API::V1;
###########################################
use strict;
use warnings;
use Log::Log4perl qw(:easy);
use JSON qw( from_json to_json );
use Pogo::Util qw( http_response_json );
use Pogo::Job;
use Pogo::Defaults qw(
    $POGO_DISPATCHER_CONTROLPORT_HOST
    $POGO_DISPATCHER_CONTROLPORT_PORT
);
use AnyEvent::HTTP;
use HTTP::Status qw( :constants );
use Plack::Request;
use Data::Dumper;
use HTTP::Request::Common;
use Sys::Hostname qw(hostname);

our $JSON = JSON->new->allow_nonref;

=head1 NAME

Pogo::API::V1 - Pogo API Handlers

=head1 SYNOPSIS

=over 4

=item C<GET /v1/jobs?max=10&offset=30>

get 10 jobs, starting at the 31st most recent

=item C<GET /v1/jobs/p0000000012>

get data for job id p0000000012

=item C<POST /v1/jobs>

submit a new job

=item C<POST /v1/jobs/p0000000007>

alter job id p0000000007

=back

...etc

=head1 DESCRIPTION

Handles URLs like C<GET /v1/jobs/p0000000011>, C<POST /v1/jobs>, etc.

=cut

###########################################
sub app {
###########################################
    my ( $class, $dispatcher ) = @_;

    return sub {
        my ( $env ) = @_;

        my $req    = Plack::Request->new( $env );
        my $path   = $req->path;
        my $method = $req->method;
        my $format = $req->param( 'format' ) || '';
        my $cb     = $req->param( 'cb' ) || '';

        DEBUG "Got v1 request for $method $path";

        my $jobid_pattern = '[a-z]{1,3}\d{10}';

        # list these in order of precedence
        my @commands = (

            {   pattern => qr{^/ping$},
                method  => 'GET',
                handler => \&ping,
            },

            # /jobs* handlers

            {   pattern => qr{^/jobs$},
                method  => 'GET',
                handler => \&listjobs
            },

            {   pattern => qr{^/jobs/$jobid_pattern$},
                method  => 'GET',
                handler => \&jobinfo
            },

            {   pattern => qr{^/jobs/$jobid_pattern/log$},
                method  => 'GET',
                handler => \&joblog
            },

            {   pattern => qr{^/jobs/$jobid_pattern/hosts$},
                method  => 'GET',
                handler => \&jobhosts
            },

            {   pattern => qr{^/jobs/$jobid_pattern/hosts/[^/]+$},
                method  => 'GET',
                handler => \&host_output
            },

            {   pattern => qr{^/jobs/last/[^/]+$},
                method  => 'GET',
                handler => \&not_implemented
            },

            {   pattern => qr{^/jobs$},
                method  => 'POST',
                handler => \&jobsubmit
            },

            # POST /jobs/[jobid] takes care of:
            # - jobhalt
            # - jobretry
            # - jobresume
            # - jobskip
            # - jobalter
            {   pattern => qr{^/jobs/$jobid_pattern$},
                method  => 'POST',
                handler => \&not_implemented
            },

            # /namespaces* handlers

            {   pattern => qr{^/namespaces$},
                method  => 'GET',
                handler => \&not_implemented
            },

            {   pattern => qr{^/namespaces/[^/]+$},
                method  => 'GET',
                handler => \&not_implemented
            },

            {   pattern => qr{^/namespaces/[^/]+/locks$},
                method  => 'GET',
                handler => \&not_implemented
            },

            {   pattern => qr{^/namespaces/[^/]+/hosts/[^/]+/tags$},
                method  => 'GET',
                handler => \&not_implemented
            },

            # loads constraints configuration for a namespace
            {   pattern => qr{^/namespaces/[^/]+/constraints$},
                method  => 'POST',
                handler => \&not_implemented
            },

            # /admin* handlers

            {   pattern => qr{^/admin/nomas$},
                method  => 'POST',
                handler => \&not_implemented
            },

        );

        foreach my $command ( @commands ) {
            if (    $method eq $command->{ method }
                and $path =~ $command->{ pattern } )
            {
                DEBUG "$path matched pattern $command->{pattern}, dispatching";
                return $command->{ handler }->( $req );
            }
        }

        return psgi_response(
            {   code   => HTTP_BAD_REQUEST,
                errors => [ "unknown request: $method '$path'" ],
                format => $format,
                cb     =>  $cb
            }
        );
    };
}

=pod

=head1 HTTP METHODS

=over 4

=item C<GET /v1/jobs>

List Pogo jobs.

Parameters:

=over 2

=item C<max>

=item C<offset>

=back

Example Request:

C<GET http://pogo.example.com/v1/jobs?max=3&offset=20>




=item C<GET /v1/jobs/:jobid>

Get basic information for a Pogo job.

Parameters: (none)

Example Request:

C<GET http://pogo.example.com/v1/jobs/p0000000003>




=item C<GET /v1/jobs/:jobid/log>

Get log entries for a Pogo job.

Parameters:

=over 2

=item C<max>

=item C<offset>

=back

Example Request:

C<GET http://pogo.example.com/v1/jobs/p0000000003/log?max=100>




=item C<GET /v1/jobs/:jobid/hosts>

Get a list of target hosts and their statuses for a Pogo job.

Parameters:

=over 2

=item C<max>

=item C<offset>

=back

Example Request:

C<GET http://pogo.example.com/v1/jobs/p0000000003/hosts?max=80>




=item C<GET /v1/jobs/:jobid/hosts/:host>

Get the output for a target host in a Pogo job.

Parameters:

=over 2

=item C<max>

=item C<offset>

=back

Example Request:

C<GET http://pogo.example.com/v1/jobs/p0000000003/hosts/a.target.host.example.com?max=500&offset=1000>




=item C<GET /v1/jobs/last/:userid>

Get the last job submitted by a given user.

Parameters: (none)

Example Request:

C<GET http://pogo.example.com/v1/jobs/last/johnqdoe>




=item C<POST /v1/jobs>

Submit a new job.

Parameters:

=over 2

=item C<range> (required)

Range expression specifying the hosts on which to execute the command.

=item C<namespace> (required)

Namespace for the job.

=item C<command> (required)

Command to execute on the target hosts.

=item C<user> (required)

User who submitted the job. If C<run_as> is not specified, it will default to this value.

=item C<password>

SSH password for the user. Either C<password> or C<client_private_key> must be provided.

=item C<client_private_key>

User's ssh private key. Either C<client_private_key> or C<password> must be provided.

=item C<pvt_key_passphrase>

Private key passphrase, if applicable.

=item C<run_as>

Username to use to connect to and execute commands on the target hosts.

=item C<timeout>

Timeout for each host command.

=item C<job_timeout>

Timeout for the overall job.

=item C<prehook>

Indicates whether or not to run prehook commands.

=item C<posthook>

Indicates whether or not to run posthook commands.

=item C<retry>

Indicates whether to retry the command if it fails.

=item C<requesthost>

The host from which the request was submitted.

=item C<email>

User's email address.

=item C<im_handle>

User's IM handle.

=item C<message>

Message describing the job.

=item C<invoked_as>

Command line used to invoke the Pogo request.

=item C<client>

Client version.

Example Request:

C<POST http://pogo.example.com/v1/jobs>

C<POST Data: range=targethost1.example.com,targethost2.example.com&namespace=front_end_web&command=sudo%20shutdown%20-f%20-r%20NOW&user=janeqdoe&password=J4n3spw&client=1.0>

=back



C<POST /v1/jobs/:jobid>

Alter a job. A job can be altered in four basic ways: jobhalt, jobretry, jobskip, jobalter. The type of alteration is specified by the C<command> parameter. Additional required and optional parameters depend on which command is issued.

=over 2

=item command: C<jobhalt>

Stops a job in progress.

Other Parameters:

=over 2

=item C<reason>

Description of why the job was halted.

=back

Example Request:

C<POST http://pogo.example.com/v1/jobs/p0000000007>

C<POST Data: command=jobhalt&reason=Decided%20I%20didn%27t%20want%20to%20continue>



=item command: C<jobretry>

Retries a failed target host.

Other Parameters:

=over 2

=item C<host> (required)

The host to retry the command on.

=back

Example Request:

C<POST http://pogo.example.com/v1/jobs/p0000000007>

C<POST Data: command=jobretry&host=some.host.example.com>



=item command: C<jobskip>

Skips a target host when doing constraints calculations.

Other Parameters:

=over 2

=item C<host> (required)

Host to ignore.

=back

Example Request:

C<POST http://pogo.example.com/v1/jobs/p0000000007>

C<POST Data: command=jobskip&some.ignoreable.host.example.com>



=item command: C<jobalter>

Alters one or more attributes of an existing job.

Other Parameters:

=over 2

=item C<attribute> (required)

=item C<value> (required)

=back

Example Requests:

C<POST http://pogo.example.com/v1/jobs/p0000000007>

C<POST Data: command=jobalter&attribute=timeout&value=36000>

C<POST http://pogo.example.com/v1/jobs/p0000000007>

C<POST Data: command=jobalter&attribute=retry&value=1&attribute=message&value=hosts%20will%20now%20retry%20one%20time>


C<POST http://pogo.example.com/v1/jobs/p0000000007>

C<POST Data: command=jobalter&attribute=command&value=sudo%20apachectl%20-k%20restart>

=back


=item C<GET /v1/namespaces>

List Pogo namespaces.

Parameters:

=over 2

=item C<max>

=item C<offset>

=back

Example Request:

C<GET http://pogo.example.com/v1/namespaces?offset=10&max=10>



=item C<GET /v1/namespaces/:namespace>

Get basic information for a namespace.

Parameters: (none)

Example Request:

C<GET http://pogo.example.com/v1/namespaces/webfrontend>



=item C<GET /v1/namespaces/:namespace/locks>

Get current "locks" for a given namespace. Locks are constraints for active jobs that may be preventing other hosts within the same job -- or others within the same namespace -- from running.

Example Request:

C<GET http://pogo.example.com/v1/namespaces/webfrontend/locks>



=item C<GET /v1/namespaces/:namespace/tags>

Get all configured tags for a namespace.

Parameters: (none)

Example Request:

C<GET http://pogo.example.com/v1/namespaces/databases/tags>



=item C<GET /v1/namespaces/:namespace/constraints>

Get all configured constraints for a namespace.

Parameters: (none)

Example Request:

C<GET http://pogo.example.com/v1/namespaces/japanfe/constraints>



=item C<POST /v1/namespaces/:namespace/constraints>

Set constraints for a namespace.

Parameters: (none)

Example Request:

C<POST http://pogo.example.com/v1/namespaces/japanfe/constraints>


=item C<POST /v1/admin/nomas>

Toggle Pogo API's ability to accept new jobs.

=back

=cut

###########################################
sub ping {
###########################################
    my ( $req ) = @_;

    DEBUG "handling ping request";

    my $format = $req->param( 'format' ) || '';
    my $cb     = $req->param( 'cb' ) || '';

    # bare-bones "yes, the API is up" response
    return psgi_response( { data   => { ping => 'pong' },
                            format => $format,
                            cb     => $cb } );
}

###########################################
sub listjobs {
###########################################
    my ( $req ) = @_;

    DEBUG "handling listjobs request";

    my $format = $req->param( 'format' ) || '';
    my $cb     = $req->param( 'cb' )     || '';
    my $max    = $req->param( 'max' )    || 20; # (so, max can't be 0)
    my $offset = $req->param( 'offset' ) || 0;

    my $data = from_json( _TEST_DATA() );
    my $jobs = $data->{ jobs };
    my $job_count = scalar @$jobs;

    # calculate start and end
    my ( $start, $end ) = get_start_end( $job_count, $max, $offset );

    # take our slice
    $jobs = [ @$jobs[ $start .. $end ] ];

    return psgi_response( { data   => { jobs => $jobs },
                            format => $format,
                            meta   => { count => $job_count },
                            cb     => $cb } );
}

###########################################
sub jobinfo {
###########################################
    my ( $req ) = @_;

    DEBUG "handling jobinfo request";

    my $format = $req->param( 'format' ) || '';
    my $cb     = $req->param( 'cb' ) || '';

    my $jobid;

    unless ( $req->path =~ m{/([^/]+)$}o ) {
        ERROR "Couldn't find job id in path: " . $req->path;
        return psgi_response(
            {   code  => HTTP_BAD_REQUEST,
                errors => [ "jobid missing from request path " . $req->path ],
                format => $format,
                cb     => $cb
            }
        );
    }

    $jobid = $1;
    my $job;

    DEBUG "looking up jobinfo for $jobid";

    my $data = from_json( _TEST_DATA() );
    foreach ( @{ $data->{ jobs } } ) {
        if ( $jobid eq $_->{ jobid } ) {
            $job = $_;
            last;
        }
    }

    unless ( $job ) {
        ERROR "no such job $job";
        return psgi_response(
            {   code   => HTTP_NOT_FOUND,
                errors  => [ "no such job $jobid" ],
                format => $format,
                cb     => $cb
            }
        );
    }

    return psgi_response( { data => { job => $job },
                            format => $format,
                            cb     => $cb } );
}

###########################################
sub joblog {
###########################################
    my ( $req ) = @_;

    DEBUG "handling joblog request";

    my $format = $req->param( 'format' ) || '';
    my $cb     = $req->param( 'cb' ) || '';
    my $max    = $req->param( 'max' )    || 300; # (so, max can't be 0)
    my $offset = $req->param( 'offset' ) || 0;

    my $jobid;

    unless ( $req->path =~ m{/([^/]+)/log$}o ) {
        ERROR "Couldn't find job id in path: " . $req->path;
        return psgi_response(
            {   code  => HTTP_BAD_REQUEST,
                errors => [ "jobid missing from request path " . $req->path ],
                format => $format,
                cb     => $cb
            }
        );
    }

    $jobid = $1;
    my $joblog;

    DEBUG "looking up joblog for $jobid";

    my $data = from_json( _TEST_DATA() );
    foreach ( @{ $data->{ jobs } } ) {
        if ( $jobid eq $_->{ jobid } ) {
            $joblog = $_->{ log };
            last;
        }
    }

    unless ( $joblog ) {
        ERROR "no such job $jobid";
        return psgi_response(
            {   code  => HTTP_NOT_FOUND,
                errors => [ "no such job $jobid" ],
                format => $format,
                cb     => $cb
            }
        );
    }

    my $log_entries = scalar @$joblog;

    # calculate start and end
    my ( $start, $end ) = get_start_end( $log_entries, $max, $offset );

    # take slice
    $log_entries = [ @$joblog[ $start .. $end ] ];

    return psgi_response( { data   => { joblog => $joblog },
                            format => $format,
                            meta   => { count  => $log_entries },
                            cb     => $cb } );
}

###########################################
sub jobhosts {
###########################################
    my ( $req ) = @_;

    DEBUG "handling jobhosts request";

    my $format = $req->param( 'format' ) || '';
    my $cb     = $req->param( 'cb' )     || '';
    my $max    = $req->param( 'max' )    || 500; # (so, max can't be 0)
    my $offset = $req->param( 'offset' ) || 0;

    unless ( $req->path =~ m{/([^/]+)/hosts$}o ) {
        ERROR "Couldn't find job id in path: " . $req->path;
        return psgi_response(
            {   code  => HTTP_BAD_REQUEST,
                errors => [ "jobid missing from request path " . $req->path ],
                format => $format,
                cb     => $cb
            }
        );
    }

    my $jobid = $1;
    my $hosts;

    DEBUG "looking up jobhosts for $jobid";

    my $data = from_json( _TEST_DATA() );
    foreach ( @{ $data->{ jobs } } ) {
        if ( $jobid eq $_->{ jobid } ) {
            $hosts = $_->{ hosts };
            last;
        }
    }

    unless ( $hosts ) {
        ERROR "no such job $jobid";
        return psgi_response(
            {   code  => HTTP_NOT_FOUND,
                errors => [ "no such job $jobid" ],
                format => $format,
                cb     => $cb
            }
        );
    }

    my $host_count = scalar keys %$hosts;

    # calculate start and end
    my ( $start, $end ) = get_start_end( $host_count, $max, $offset ); 

    # TODO: comment this line noise :/
    $hosts = {
               map { $_ => $hosts->{ $_ }
             } (
                 sort { $a cmp $b } keys %$hosts
               )[ $start .. $end ] };

    return psgi_response( { data   => { hosts => $hosts },
                            format => $format,
                            meta   => { count => $host_count },
                            cb     => $cb } );
}

###########################################
sub host_output {
###########################################
    my ( $req ) = @_;

    DEBUG "handling host_output request";

    my $format = $req->param( 'format' ) || '';
    my $cb     = $req->param( 'cb' )     || '';
    my $max    = $req->param( 'max' )    || 500; # (so, max can't be 0)
    my $offset = $req->param( 'offset' ) || 0;

    unless ( $req->path =~ m{/([^/]+)/hosts/([^/]+)$}o ) {
        ERROR "Couldn't find job id and/or hostname in path: " . $req->path;
        return psgi_response(
            {   code   => HTTP_BAD_REQUEST,
                errors => [ "jobid and/or hostname missing from request path " . $req->path ],
                format => $format,
                cb     => $cb
            }
        );
    }

    my ( $jobid, $host ) = ( $1, $2 );
    my $output;

    DEBUG "getting command output for jobid $jobid on host $host";

    my $data = from_json( _TEST_DATA() );
    $output = $data->{ output }->{ $jobid }->{ $host };

    unless ( $output ) {
        ERROR "no such job/host combination $jobid/$host";
        return psgi_response(
            {   code  => HTTP_NOT_FOUND,
                errors => [ "no such job/host combination $jobid/$host" ],
                format => $format,
                cb     => $cb
            }
        );
    }

    my $output_lines = scalar @$output;

    # calculate start and end
    my ( $start, $end ) = get_start_end( $output_lines, $max, $offset );

    # take slice
    $output = [ @$output[ $start .. $end ] ];

    return psgi_response( { data   => { output => $output },
                            format => $format,
                            meta   => { count => $output_lines },
                            cb     => $cb } );
}

###########################################
sub jobsubmit {
###########################################
    my ( $req ) = @_;

    my $format  = $req->param( 'format' );
    my $job = Pogo::Job->from_query( $req->content() );

    DEBUG "Received job: ", $job->as_string();

    return sub {
        my ( $response_cb ) = @_;

        # Submit job to dispatcher
        job_post_to_dispatcher( $job, $response_cb, $format );
    };
}

###########################################
sub job_post_to_dispatcher {
###########################################
    my ( $job, $response_cb, $format ) = @_;

    $format ||= '';

    my $cp          = Pogo::Dispatcher::ControlPort->new();
    my $cp_base_url = $cp->base_url();

    DEBUG "Submitting job to $cp_base_url (task=", $job->task_name(), ")";

    my $http_req = POST "$cp_base_url/jobsubmit", [ %{ $job->as_hash() } ];

    http_post $http_req->url(), $http_req->content(),
        headers => $http_req->headers(),
        sub {
        my ( $data, $hdr ) = @_;

        DEBUG "API received $hdr->{ Status } response from $cp_base_url: ",
            "[$data]";

        my $rc;
        my $message;

        eval { $data = from_json( $data ); };

        if ( $@ ) {
            ERROR "invalid response received from dispatcher: $@";
            $response_cb->(
                psgi_response(
                    {   code => HTTP_INTERNAL_SERVER_ERROR,
                        meta => {
                            rc     => 'fail',
                            status => $hdr->{ Status }
                        },
                        errors =>
                            [ "problem in communication with dispatcher: $@" ],
                        format => $format
                    }
                )
            );
        } else {
            $response_cb->(
                psgi_response(
                    {   meta => {
                            rc     => $data->{ rc },
                            status => $hdr->{ Status }
                        },
                        data   => { message => $data->{ message } },
                        format => $format
                    }
                )
            );
        }
        };
}

###########################################
sub not_implemented {
###########################################
    my ( $req ) = @_;

    my $path   = $req->path;
    my $method = $req->method;
    my $format = $req->param( 'format' ) || '';
    my $cb     = $req->param( 'cb' ) || '';

    return psgi_response(
        {   code   => HTTP_NOT_IMPLEMENTED,
            errors => [ "not implemented yet: $method '$path'" ],
            format => $format,
            cb     => $cb
        }
    );
}

###########################################
sub psgi_response {
###########################################
    my ( $args ) = @_;

    my $code   = $args->{ code } || HTTP_OK;  # has to be Perl boolean true
    my $meta   = $args->{ meta };
    my $data   = $args->{ data };
    my $errors = $args->{ errors };
    my $format = $args->{ format } || 'json';
    my $cb     = $args->{ cb } || '';

    my %content_type_headers = (
        'json'        => 'application/json',
        'json-pretty' => 'application/json',
    );
    #'yaml'        => 'text/plain; charset=utf-8'

    my %cb_formats = map { $_ => 1 } ( 'json', 'json-pretty' );

    return psgi_response(
        { code => HTTP_BAD_REQUEST, errors => [ "format '$format' not known" ], cb => $cb }
    ) unless $content_type_headers{ $format };

    $meta->{ hostname } = hostname();

    # construct body for PSGI response
    my $body = {
        'meta'     => $meta,
        'response' => $data
    };

    $body->{ errors } = $errors
        if defined $errors;

    # format body appropriately
    if ( 'json' eq $format ) {

        $body = to_json( $body );

    } elsif ( 'json-pretty' eq $format ) {

        $body = $JSON->pretty->encode( $body );

    } else {
        LOGDIE "unexpected format error for format '$format'";
    }

    # add wrapping JSON callback if requested
    if ( $cb ) {

        return psgi_response(
            { code   => HTTP_BAD_REQUEST,
              errors => [ "format '$format' can't be wrapped in a JSON callback" ],
              format => $format }
        ) unless $cb_formats{ $format };

        $body = "$cb($body)";
    }

    return [
        $code, [ 'Content-Type' => $content_type_headers{ $format } ],
        [ $body, "\n" ]
    ];
}

sub get_start_end {
    my ( $total, $max, $offset ) = @_;

    return if ! defined $total;
    return ( 0, -1 ) if ! defined $max; # whole thing
    $offset = 0 if ! defined $offset;   # start at beginning

    my $start = ( $offset > $total - 1 )    ? $total - 1 : $offset;
    my $end   = ( $offset + $max > $total ) ? $total - 1 : $offset + $max - 1;

    return ( $start, $end );
}

=head1 LICENSE

Copyright (c) 2010-2012 Yahoo! Inc. All rights reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
imitations under the License.

=head1 AUTHORS

Mike Schilli <m@perlmeister.com>
Ian Bettinger <ibettinger@yahoo.com>

Many thanks to the following folks for implementing the
original version of Pogo: 

Andrew Sloane <andy@a1k0n.net>, 
Michael Fischer <michael+pogo@dynamine.net>,
Nicholas Harteau <nrh@hep.cat>,
Nick Purvis <nep@noisetu.be>,
Robert Phan <robert.phan@gmail.com>,
Srini Singanallur <ssingan@yahoo.com>,
Yogesh Natarajan <yogesh_ny@yahoo.co.in>

=cut

sub _TEST_DATA {

    return <<'END_JSON'
{
  "jobs" : [
      {
          "jobid"       : "p0000000009",
          "command"     : "df -h",
          "range"       : "[\"storehost[8-9].example.com\"]",
          "namespace"   : "example",
          "user"        : "joebob",
          "run_as"      : "joebob",
          "state"       : "running",
          "concurrent"  : "1",
          "host_count"  : "2",
          "job_timeout" : "15000",
          "timeout"     : "1200",
          "prehook"     : "0",
          "posthook"    : "0",
          "retry"       : "0",
          "requesthost" : "desktop.example.com",
          "invoked_as"  : "/usr/bin/pogo run -h host2.example.com --concurrent 4 'df -h'",
          "start_time"  : 1336094404.363,
          "client"      : "4.0.0",

          "hosts" : { "storehost8.example.com" : { "state": "finished",
                                                   "start_time" : 1336094406,
                                                   "finish_time" : 1336094408,
                                                   "output": "http://pogo-worker1.example.com/pogo_output/p0000000009/storehost8.example.com.txt" },
                      "storehost9.example.com" : { "state": "running",
                                                   "start_time" : 1336094410,
                                                   "output": "http://pogo-worker1.example.com/pogo_output/p0000000009/storehost9.example.com.txt" } },
          "log" : [
              {
                  "time": 1336094405,
                  "type": "jobstate",
                  "range": "[\"storehost[8-9].example.com\"]",
                  "state": "gathering",
                  "message": "job created; fetching hostinfo"
              },
              {
                  "time": 1336094405.33,
                  "type": "jobstate",
                  "range": "[\"storehost[8-9].example.com\"]",
                  "state": "gathering",
                  "message": "job created; finished fetching hostinfo"
              },
              {
                  "time": 1336094405.4523,
                  "type": "jobstate",
                  "range": "[\"storehost[8-9].example.com\"]",
                  "state": "running",
                  "message": "constraints computed"
              },
              {
                  "time": 1336094405.466,
                  "type": "hoststate",
                  "host": "storehost8.example.com",
                  "state": "waiting",
                  "message": "determining run order..."
              },
              {
                  "time": 1336094405.87,
                  "type": "hoststate",
                  "host": "storehost9.example.com",
                  "state": "waiting",
                  "message": "determining run order..."
              },
              {
                  "time": 1336094405.909,
                  "type": "hoststate",
                  "host": "storehost8.example.com",
                  "state": "ready",
                  "message": "connecting to host..."
              },
              {
                  "time": 1336094406.0035,
                  "type": "hoststate",
                  "host": "storehost9.example.com",
                  "state": "waiting",
                  "message": "waiting for (SOME CONSTRAINT)"
              },
              {
                  "time": 1336094406.11,
                  "type": "hoststate",
                  "host": "storehost8.example.com",
                  "state": "running",
                  "output": "http://pogo-worker1.example.com/pogo_output/p0000000009/storehost8.example.com.txt",
                  "message": "started"
              },
              {
                  "time": 1336094408.35,
                  "type": "hoststate",
                  "host": "storehost8.example.com",
                  "state": "finished",
                  "exitstatus" : "0",
                  "message": "0"
              },
              {
                  "time": 1336094409.34,
                  "type": "hoststate",
                  "host": "storehost9.example.com",
                  "state": "ready",
                  "message": "connecting to host..."
              },
              {
                  "time": 1336094410.575,
                  "type": "hoststate",
                  "host": "storehost9.example.com",
                  "state": "running",
                  "output": "http://pogo-worker1.example.com/pogo_output/p0000000009/storehost8.example.com.txt",
                  "message": "started"
              }
                 ]
      },
      {
          "jobid"       : "p0000000008",
          "command"     : "uptime",
          "range"       : "[\"host2.example.com\"]",
          "namespace"   : "example",
          "user"        : "sallyfoo",
          "run_as"      : "sallyfoo",
          "state"       : "finished",
          "concurrent"  : "1",
          "host_count"  : "1",
          "job_timeout" : "15000",
          "timeout"     : "1200",
          "prehook"     : "0",
          "posthook"    : "0",
          "retry"       : "0",
          "requesthost" : "clienthost.example.com",
          "invoked_as"  : "/usr/bin/pogo run -h host2.example.com --concurrent 4 uptime",
          "start_time"  : 1336094397.8485,
          "client"      : "4.0.0",
          "hosts" : { "host2.example.com": { "state": "finished", "start_time": 1336094410, "finish_time": 1336094420, "output": "http://pogo-worker1.example.com/pogo_output/p0000000008/host2.example.com.txt" } },

          "log" : [
              {
                  "time": 1336094397.8485,
                  "type": "jobstate",
                  "range": "host2.example.com",
                  "state": "gathering",
                  "message": "job created; fetching hostinfo"
              },
              {
                  "time": 1336094398,
                  "type": "jobstate",
                  "range": "host2.example.com",
                  "state": "gathering",
                  "message": "job created; finished fetching hostinfo"
              },
              {
                  "time": 1336094399,
                  "type": "jobstate",
                  "range": "host2.example.com",
                  "state": "running",
                  "message": "constraints computed"
              },
              {
                  "time": 1336094400,
                  "type": "hoststate",
                  "host": "host2.example.com",
                  "state": "waiting",
                  "message": "determining run order..."
              },
              {
                  "time": 1336094405,
                  "type": "hoststate",
                  "host": "host2.example.com",
                  "state": "waiting",
                  "message": "waiting for (SOME CONSTRAINT)"
              },
              {
                  "time": 1336094410,
                  "type": "hoststate",
                  "host": "host2.example.com",
                  "state": "ready",
                  "message": "connecting to host..."
              },
              {
                  "time": 1336094415,
                  "type": "hoststate",
                  "host": "host2.example.com",
                  "state": "running",
                  "output": "http://pogo-worker1.example.com/pogo_output/p0000000008/host2.example.com.txt",
                  "message": "started"
              },
              {
                  "time": 1336094420,
                  "type": "hoststate",
                  "host": "host2.example.com",
                  "state": "finished",
                  "exitstatus" : "0",
                  "message": "0"
              },
              {
                  "time": 1336094421,
                  "type": "jobstate",
                  "state": "finished",
                  "message": "no more hosts to run"
              }
              ]
      },

      {
          "jobid"       : "p0000000007",
          "command"     : "sudo apachectl -k graceful-stop; rpm -iv  SomePkg.3.11.i386.rpm; sudo apachectl -k start; sudo apachectl -k status",
          "range"       : "[\"host[1-4].example.com\"]",
          "namespace"   : "crawler",
          "user"        : "johnqdoe",
          "run_as"      : "johnqdoe",
          "state"       : "finished",
          "concurrent"  : "1",
          "host_count"  : "4",
          "job_timeout" : "15000",
          "timeout"     : "15000",
          "prehook"     : "0",
          "posthook"    : "0",
          "retry"       : "0",
          "requesthost" : "clienthost.example.com",
          "invoked_as"  : "/usr/bin/pogo run -h host2.example.com --concurrent 4 'sudo apachectl -k graceful-stop; rpm -iv  SomePkg.3.11.i386.rpm; sudo apachectl -k start; sudo apachectl -k status'",
          "start_time"  : 1336095397.412,
          "client"      : "4.0.0",

          "hosts" : { "host1.example.com": { "state": "finished", "start_time": 1336095409, "finish_time": 1336095416, "output": "http://pogo-worker1.example.com/pogo_output/p0000000007/host1.example.com.txt" },
                      "host2.example.com": { "state": "finished", "start_time": 1336095417, "finish_time": 1336095419, "output": "http://pogo-worker1.example.com/pogo_output/p0000000007/host2.example.com.txt" },
                      "host3.example.com": { "state": "finished", "start_time": 1336095420, "finish_time": 1336095422, "output": "http://pogo-worker1.example.com/pogo_output/p0000000007/host3.example.com.txt" },
                      "host4.example.com": { "state": "finished", "start_time": 1336095424, "finish_time": 1336095427, "output": "http://pogo-worker1.example.com/pogo_output/p0000000007/host4.example.com.txt" } },

          "log" : [
              {
                  "time": 1336095397.412,
                  "type": "jobstate",
                  "range": "host[1-4].example.com",
                  "state": "gathering",
                  "message": "job created; fetching hostinfo"
              },
              {
                  "time": 1336095400,
                  "type": "jobstate",
                  "range": "host[1-4].example.com",
                  "state": "gathering",
                  "message": "job created; finished fetching hostinfo"
              },
              {
                  "time": 1336095403,
                  "type": "jobstate",
                  "range": "host[1-4].example.com",
                  "state": "running",
                  "message": "constraints computed"
              },
              {
                  "time": 1336095405,
                  "type": "hoststate",
                  "host": "host1.example.com",
                  "state": "waiting",
                  "message": "determining run order..."
              },
              {
                  "time": 1336095406,
                  "type": "hoststate",
                  "host": "host3.example.com",
                  "state": "waiting",
                  "message": "determining run order..."
              },
              {
                  "time": 1336095407,
                  "type": "hoststate",
                  "host": "host2.example.com",
                  "state": "waiting",
                  "message": "determining run order..."
              },
              {
                  "time": 1336095408,
                  "type": "hoststate",
                  "host": "host4.example.com",
                  "state": "waiting",
                  "message": "determining run order..."
              },
              {
                  "time": 1336095409,
                  "type": "hoststate",
                  "host": "host1.example.com",
                  "state": "ready",
                  "message": "connecting to host..."
              },
              {
                  "time": 1336095410,
                  "type": "hoststate",
                  "host": "host2.example.com",
                  "state": "waiting",
                  "message": "waiting for (SOME CONSTRAINT)"
              },
              {
                  "time": 1336095411,
                  "type": "hoststate",
                  "host": "host4.example.com",
                  "state": "waiting",
                  "message": "waiting for (SOME CONSTRAINT)"
              },
              {
                  "time": 1336095414,
                  "type": "hoststate",
                  "host": "host3.example.com",
                  "state": "waiting",
                  "message": "waiting for (SOME CONSTRAINT)"
              },
              {
                  "time": 1336095414,
                  "type": "hoststate",
                  "host": "host1.example.com",
                  "state": "running",
                  "output": "http://pogo-worker1.example.com/pogo_output/p0000000007/host1.example.com.txt",
                  "message": "started"
              },
              {
                  "time": 1336095416,
                  "type": "hoststate",
                  "host": "host1.example.com",
                  "state": "finished",
                  "exitstatus" : "0",
                  "message": "0"
              },
              {
                  "time": 1336095417,
                  "type": "hoststate",
                  "host": "host2.example.com",
                  "state": "ready",
                  "message": "connecting to host..."
              },
              {
                  "time": 1336095418,
                  "type": "hoststate",
                  "host": "host2.example.com",
                  "state": "running",
                  "output": "http://pogo-worker1.example.com/pogo_output/p0000000007/host2.example.com.txt",
                  "message": "started"
              },
              {
                  "time": 1336095419,
                  "type": "hoststate",
                  "host": "host2.example.com",
                  "state": "finished",
                  "exitstatus" : "0",
                  "message": "0"
              },
              {
                  "time": 1336095420,
                  "type": "hoststate",
                  "host": "host3.example.com",
                  "state": "ready",
                  "message": "connecting to host..."
              },
              {
                  "time": 1336095421,
                  "type": "hoststate",
                  "host": "host3.example.com",
                  "state": "running",
                  "output": "http://pogo-worker1.example.com/pogo_output/p0000000007/host3.example.com.txt",
                  "message": "started"
              },
              {
                  "time": 1336095422,
                  "type": "hoststate",
                  "host": "host3.example.com",
                  "state": "finished",
                  "exitstatus" : "0",
                  "message": "0"
              },
              {
                  "time": 1336095424,
                  "type": "hoststate",
                  "host": "host4.example.com",
                  "state": "ready",
                  "message": "connecting to host..."
              },
              {
                  "time": 1336095425,
                  "type": "hoststate",
                  "host": "host4.example.com",
                  "state": "running",
                  "output": "http://pogo-worker1.example.com/pogo_output/p0000000007/host4.example.com.txt",
                  "message": "started"
              },
              {
                  "time": 1336095427,
                  "type": "hoststate",
                  "host": "host4.example.com",
                  "state": "finished",
                  "exitstatus" : "0",
                  "message": "0"
              },
              {
                  "time": 1336095429,
                  "type": "jobstate",
                  "state": "finished",
                  "message": "no more hosts to run"
              }
              ]
      },
      {
        "jobid"       : "p0000000006",
        "command"     : "sudo apachectl -k restart",
        "range"       : "[\"host2.example.com\"]",
        "namespace"   : "example",
        "user"        : "johnqdoe",
        "run_as"      : "johnqdoe",
        "state"       : "finished",
        "concurrent"  : "1",
        "host_count"  : "1",
        "job_timeout" : "15000",
        "timeout"     : "15000",
        "prehook"     : "0",
        "posthook"    : "0",
        "retry"       : "0",
        "requesthost" : "clienthost.example.com",
        "invoked_as"  : "/usr/bin/pogo run -h host2.example.com --concurrent 4 'sudo apachectl -k restart'",
        "start_time"  : 1336096997.32125,
        "client"      : "4.0.0",

          "hosts" : { "host2.example.com": { "state": "finished", "start_time": 1336097000, "finish_time": 1336097006, "output": "http://pogo-worker1.example.com/pogo_output/p0000000006/host2.example.com.txt" } },

          "log" : [
              {
                  "time": 1336096997.32125,
                  "type": "jobstate",
                  "range": "host2.example.com",
                  "state": "gathering",
                  "message": "TEST JOB LOG MESSAGE"
              },
              {
                  "time": 1336097000,
                  "type": "hoststate",
                  "host": "host7.example.com",
                  "state": "running",
                  "output": "http://pogo-worker1.example.com/pogo_output/p0000000006/host2.example.com.txt",
                  "message": "TEST HOST LOG MESSAGE"
              },
              {
                  "time": 1336097007,
                  "type": "jobstate",
                  "state": "finished",
                  "message": "TEST JOB LOG MESSAGE"
              }
              ]
      },

      {
        "jobid"       : "p0000000005",
        "command"     : "whoami; uptime",
        "range"       : "[\"host[6-8].example.com\"]",
        "namespace"   : "crawler",
        "user"        : "sallyfoo",
        "run_as"      : "robotuser",
        "state"       : "finished",
        "concurrent"  : "1",
        "host_count"  : "3",
        "job_timeout" : "15000",
        "timeout"     : "15000",
        "prehook"     : "0",
        "posthook"    : "0",
        "retry"       : "0",
        "requesthost" : "clienthost.example.com",
        "invoked_as"  : "/usr/bin/pogo run -h host2.example.com --concurrent 4 'whoami; uptime'",
        "start_time"  : 1336098399.00825,
        "client"      : "4.0.0",

        "hosts" : { "host6.example.com": { "state": "finished", "start_time": 1336098400, "finish_time": 1336098401, "output": "http://pogo-worker1.example.com/pogo_output/p0000000005/host6.example.com.txt" },
                    "host7.example.com": { "state": "finished", "start_time": 1336098402, "finish_time": 1336098403, "output": "http://pogo-worker1.example.com/pogo_output/p0000000005/host7.example.com.txt" },
                    "host8.example.com": { "state": "finished", "start_time": 1336098404, "finish_time": 1336098405, "output": "http://pogo-worker1.example.com/pogo_output/p0000000005/host8.example.com.txt" } },

          "log" : [
              {
                  "time": 1336098399.00825,
                  "type": "jobstate",
                  "range": "host[6-8].example.com",
                  "state": "gathering",
                  "message": "TEST JOB LOG MESSAGE"
              },
              {
                  "time":  1336098400,
                  "type": "hoststate",
                  "host": "host7.example.com",
                  "state": "running",
                  "output": "http://somehost.example.com/someurl.txt",
                  "message": "TEST HOST LOG MESSAGE"
              },
              {
                  "time":  1336098410,
                  "type": "jobstate",
                  "state": "finished",
                  "message": "TEST JOB LOG MESSAGE"
              }
              ]
      },
      {
        "jobid"       : "p0000000004",
        "command"     : "find /some/directory -type f -mmin -20",
        "range"       : "[\"host[1-4].pub.example.com\"]",
        "namespace"   : "publisher",
        "user"        : "sallyfoo",
        "run_as"      : "sallyfoo",
        "state"       : "finished",
        "host_count"  : "4",
        "job_timeout" : "15000",
        "timeout"     : "15000",
        "prehook"     : "0",
        "posthook"    : "0",
        "retry"       : "0",
        "requesthost" : "clienthost.example.com",
        "invoked_as"  : "/usr/bin/pogo run -h host2.example.com --concurrent 4 'find /some/directory -type f -mmin -20'",
        "start_time"  : 1336197397.19378,
        "client"      : "4.0.0",

          "hosts" : { "host1.pub.example.com": { "state": "finished", "start_time": 1336197403, "finish_time": 1336197404, "output": "http://somehost/some.directory/" },
                      "host2.pub.example.com": { "state": "finished", "start_time": 1336197403, "finish_time": 1336197404, "output": "http://somehost/some.directory/" },
                      "host3.pub.example.com": { "state": "finished", "start_time": 1336197403, "finish_time": 1336197404, "output": "http://somehost/some.directory/" },
                      "host4.pub.example.com": { "state": "finished", "start_time": 1336197403, "finish_time": 1336197405, "output": "http://somehost/some.directory/" } },

          "log" : [
              {
                  "time": 1336197397.19378,
                  "type": "jobstate",
                  "range": "host[1-4].pub.example.com",
                  "state": "gathering",
                  "message": "TEST JOB LOG MESSAGE"
              },
              {
                  "time": 1336197403,
                  "type": "hoststate",
                  "host": "host2.pub.example.com",
                  "state": "waiting",
                  "message": "SOME HOST MESSAGE"
              },
              {
                  "time": 1336197406,
                  "type": "jobstate",
                  "state": "finished",
                  "message": "no more hosts to run"
              }
              ]
      }
           ],

  "output" : {
      "p0000000009" : { "storehost8.example.com" : [
                            { "ts": 1336094406.003, "type": "STDOUT", "task":"p0000000009/storehost8.example.com", "data": "joebob@storehost8.example.com's password: \r\n" },
                            { "ts": 1336094406.02, "type": "STDOUT", "task":"p0000000009/storehost8.example.com", "data": "joebob@storehost8.example.com's password: \r\n" },
                            { "ts": 1336094406.229, "type": "STDOUT", "task":"p0000000009/storehost8.example.com", "data": "Password:\r\n" },
                            { "ts": 1336094406.231, "type": "STDOUT", "task":"p0000000009/storehost8.example.com", "data": "\r\n" },
                            { "ts": 1336094406.2356, "type": "STDOUT", "task":"p0000000009/storehost8.example.com", "data": "pogo-worker: loaded; command='df -h', retry=0, timeout=1200\r\n" },
                            { "ts": 1336094406.3, "type": "STDOUT", "task":"p0000000009/storehost8.example.com", "data": "pogo-worker: running command 'df -h'\r\n" },
                            { "ts": 1336094406.45, "type": "STDOUT", "task":"p0000000009/storehost8.example.com", "data": "Filesystem            Size  Used Avail Use% Mounted on\r\n/dev/sda2              30G   19G   10G  65% /\r\n/dev/sda1              30G   19G   10G  65% /boot\r\n" },
                            { "ts": 1336094406.567, "type": "STDOUT", "task":"p0000000009/storehost8.example.com", "data": "/dev/hdc               30G   19G   10G  65% /mnt\r\npogo-worker: command exit 0\r\nRemoved the stub /tmp/N6OwBasJjC \r\n\r\n" },
                            { "ts": 1336094406.82, "type": "STDOUT", "task":"p0000000009/storehost8.example.com", "data": "Connection to storehost8.example.com closed.\r\r\n" },
                            { "ts": 1336094406.903, "type": "STDOUT", "task":"p0000000009/storehost8.example.com", "data": "joebob@storehost8.example.com's password: \r\n" },
                            { "ts": 1336094407.348, "type": "STDOUT", "task":"p0000000009/storehost8.example.com", "data": "Connection to storehost8.example.com closed.\r\r\n" },
                            { "ts": 1336094408, "type": "STDOUT", "task":"p0000000009/storehost8.example.com", "data": "" },
                            { "ts": 1336094408.12, "type": "EXIT", "task":"p0000000009/storehost8.example.com", "data": "0" }

                                              ],
                        "storehost9.example.com" : [
                            { "ts": 1336094410.6576, "type": "STDOUT", "task":"p0000000009/storehost9.example.com", "data": "joebob@storehost9.example.com's password: \r\n" },
                            { "ts": 1336094410.7, "type": "STDOUT", "task":"p0000000009/storehost9.example.com", "data": "joebob@storehost9.example.com's password: \r\n" },
                            { "ts": 1336094410.8, "type": "STDOUT", "task":"p0000000009/storehost9.example.com", "data": "Password:\r\n" },
                            { "ts": 1336094410.938, "type": "STDOUT", "task":"p0000000009/storehost9.example.com", "data": "\r\n" },
                            { "ts": 1336094411, "type": "STDOUT", "task":"p0000000009/storehost9.example.com", "data": "pogo-worker: loaded; command='df -h', retry=0, timeout=1200\r\n" },
                            { "ts": 1336094412.56, "type": "STDOUT", "task":"p0000000009/storehost9.example.com", "data": "pogo-worker: running command 'df -h'\r\n" }
                                              ]
 },
      "p0000000008" : { "host2.example.com" : [
                            { "ts": 1336094410, "type": "STDOUT", "task":"p0000000008/host2.example.com", "data": "sallyfoo@host2.example.com's password:" },
                            { "ts": 1336094412, "type": "STDERR", "task":"p0000000008/host2.example.com", "data": "an error occurred" },
                            { "ts": 1336094415, "type": "STDOUT", "task":"p0000000008/host2.example.com", "data": "some command output" },
                            { "ts": 1336094420, "type": "STDOUT", "task":"p0000000008/host2.example.com", "data": "more command output..." },
                            { "ts": 1336094420.5, "type": "EXIT", "task":"p0000000008/host2.example.com", "data": "0" }
                                              ] },

      "p0000000007" : { "host4.example.com" : [
                            { "ts": 1336095424, "type": "STDOUT", "task":"p0000000007/host4.example.com", "data": "johnqdoe@host4.example.com's password:" },
                            { "ts": 1336095425, "type": "STDERR", "task":"p0000000007/host4.example.com", "data": "an error occurred" },
                            { "ts": 1336095425.5, "type": "STDOUT", "task":"p0000000007/host4.example.com", "data": "some command output" },
                            { "ts": 1336095427, "type": "STDOUT", "task":"p0000000007/host4.example.com", "data": "more command output..." },
                            { "ts": 1336095427.5, "type": "EXIT", "task":"p0000000007/host4.example.com", "data": "0" }
                                              ],

                        "host3.example.com" : [
                            { "ts": 1336095420, "type": "STDOUT", "task":"p0000000007/host3.example.com", "data": "johnqdoe@host3.example.com's password:" },
                            { "ts": 1336095421, "type": "STDERR", "task":"p0000000007/host3.example.com", "data": "an error occurred" },
                            { "ts": 1336095421.23, "type": "STDOUT", "task":"p0000000007/host3.example.com", "data": "some command output" },
                            { "ts": 1336095422, "type": "STDOUT", "task":"p0000000007/host3.example.com", "data": "more command output..." },
                            { "ts": 1336095422.5, "type": "EXIT", "task":"p0000000007/host3.example.com", "data": "0" }
                                              ],

                        "host2.example.com" : [
                            { "ts": 1336095417, "type": "STDOUT", "task":"p0000000007/host2.example.com", "data": "johnqdoe@host2.example.com's password:" },
                            { "ts": 1336095417.9, "type": "STDERR", "task":"p0000000007/host2.example.com", "data": "an error occurred" },
                            { "ts": 1336095418, "type": "STDOUT", "task":"p0000000007/host2.example.com", "data": "some command output" },
                            { "ts": 1336095419, "type": "STDOUT", "task":"p0000000007/host2.example.com", "data": "more command output..." },
                            { "ts": 1336095419.5, "type": "EXIT", "task":"p0000000007/host2.example.com", "data": "0" }
                                              ],

                        "host1.example.com" : [
                            { "ts": 1336095409, "type": "STDOUT", "task":"p0000000007/host1.example.com", "data": "johnqdoe@host1.example.com's password:" },
                            { "ts": 1336095413, "type": "STDERR", "task":"p0000000007/host1.example.com", "data": "an error occurred" },
                            { "ts": 1336095413.23, "type": "STDOUT", "task":"p0000000007/host1.example.com", "data": "some command output" },
                            { "ts": 1336095416, "type": "STDOUT", "task":"p0000000007/host1.example.com", "data": "more command output..." },
                            { "ts": 1336095416.5, "type": "EXIT", "task":"p0000000007/host1.example.com", "data": "0" }
                                              ] },

      "p0000000006" : { "host2.example.com" : [
                            { "ts": 1336097000, "type": "STDOUT", "task":"p0000000006/host2.example.com", "data": "johnqdoe@host2.example.com's password:" },
                            { "ts": 1336097003, "type": "STDERR", "task":"p0000000006/host2.example.com", "data": "an error occurred" },
                            { "ts": 1336097004.45, "type": "STDOUT", "task":"p0000000006/host2.example.com", "data": "some command output" },
                            { "ts": 1336097006, "type": "STDOUT", "task":"p0000000006/host2.example.com", "data": "more command output..." },
                            { "ts": 1336097006.5, "type": "EXIT", "task":"p0000000006/host2.example.com", "data": "0" }
                                              ] },

      "p0000000005" : { "host8.example.com" : [
                            { "ts": 1336098404, "type": "STDOUT", "task":"p0000000005/host8.example.com", "data": "robotuser@host8.example.com's password:" },
                            { "ts": 1336098404.234, "type": "STDERR", "task":"p0000000005/host8.example.com", "data": "an error occurred" },
                            { "ts": 1336098404.45345, "type": "STDOUT", "task":"p0000000005/host8.example.com", "data": "some command output" },
                            { "ts": 1336098405, "type": "STDOUT", "task":"p0000000005/host8.example.com", "data": "more command output..." },
                            { "ts": 1336098405.5, "type": "EXIT", "task":"p0000000005/host8.example.com", "data": "0" }
                                              ],

                        "host7.example.com" : [
                            { "ts": 1336098402, "type": "STDOUT", "task":"p0000000005/host7.example.com", "data": "robotuser@host7.example.com's password:" },
                            { "ts": 1336098402.2, "type": "STDERR", "task":"p0000000005/host7.example.com", "data": "an error occurred" },
                            { "ts": 1336098402.4567, "type": "STDOUT", "task":"p0000000005/host7.example.com", "data": "some command output" },
                            { "ts": 1336098403, "type": "STDOUT", "task":"p0000000005/host7.example.com", "data": "more command output..." },
                            { "ts": 1336098403.5, "type": "EXIT", "task":"p0000000005/host7.example.com", "data": "0" }
                                              ],

                        "host6.example.com" : [
                            { "ts": 1336098400, "type": "STDOUT", "task":"p0000000005/host6.example.com", "data": "robotuser@host6.example.com's password:" },
                            { "ts": 1336098400.9, "type": "STDERR", "task":"p0000000005/host6.example.com", "data": "an error occurred" },
                            { "ts": 1336098400.98, "type": "STDOUT", "task":"p0000000005/host6.example.com", "data": "some command output" },
                            { "ts": 1336098401, "type": "STDOUT", "task":"p0000000005/host6.example.com", "data": "more command output..." },
                            { "ts": 1336098401.5, "type": "EXIT", "task":"p0000000005/host6.example.com", "data": "0" }
                                              ] },

      "p0000000004" : { "host3.pub.example.com" : [
                            { "ts": 1336197403, "type": "STDOUT", "task":"p0000000004/host3.pub.example.com", "data": "sallyfoo@host3.pub.example.com's password:" },
                            { "ts": 1336197403.2, "type": "STDERR", "task":"p0000000004/host3.pub.example.com", "data": "an error occurred" },
                            { "ts": 1336197403.56, "type": "STDOUT", "task":"p0000000004/host3.pub.example.com", "data": "some command output" },
                            { "ts": 1336197404, "type": "STDOUT", "task":"p0000000004/host3.pub.example.com", "data": "more command output..." },
                            { "ts": 1336197404.5, "type": "EXIT", "task":"p0000000004/host3.pub.example.com", "data": "0" }
                                                  ],

                        "host4.pub.example.com" : [
                            { "ts": 1336197403, "type": "STDOUT", "task":"p0000000004/host4.pub.example.com", "data": "sallyfoo@host4.pub.example.com's password:" },
                            { "ts": 1336197403.4, "type": "STDERR", "task":"p0000000004/host4.pub.example.com", "data": "an error occurred" },
                            { "ts": 1336197404.234, "type": "STDOUT", "task":"p0000000004/host4.pub.example.com", "data": "some command output" },
                            { "ts": 1336197405, "type": "STDOUT", "task":"p0000000004/host4.pub.example.com", "data": "more command output..." },
                            { "ts": 1336197405.5, "type": "EXIT", "task":"p0000000004/host4.pub.example.com", "data": "0" }
                                                  ],

                        "host2.pub.example.com" : [
                            { "ts": 1336197403, "type": "STDOUT", "task":"p0000000004/host2.pub.example.com", "data": "sallyfoo@host2.pub.example.com's password:" },
                            { "ts": 1336197403.3, "type": "STDERR", "task":"p0000000004/host2.pub.example.com", "data": "an error occurred" },
                            { "ts": 1336197403.5696, "type": "STDOUT", "task":"p0000000004/host2.pub.example.com", "data": "some command output" },
                            { "ts": 1336197404, "type": "STDOUT", "task":"p0000000004/host2.pub.example.com", "data": "more command output..." },
                            { "ts": 1336197404.5, "type": "EXIT", "task":"p0000000004/host2.pub.example.com", "data": "0" }
                                                  ],

                        "host1.pub.example.com" : [
                            { "ts": 1336197403, "type": "STDOUT", "task":"p0000000004/host1.pub.example.com", "data": "sallyfoo@host1.pub.example.com's password:" },
                            { "ts": 1336197403.0476, "type": "STDERR", "task":"p0000000004/host1.pub.example.com", "data": "an error occurred" },
                            { "ts": 1336197403.957, "type": "STDOUT", "task":"p0000000004/host1.pub.example.com", "data": "some command output" },
                            { "ts": 1336197404, "type": "STDOUT", "task":"p0000000004/host1.pub.example.com", "data": "more command output..." },
                            { "ts": 1336197404.5, "type": "EXIT", "task":"p0000000004/host1.pub.example.com", "data": "0" }
                                                  ]  }
   },

  "namespaces" : [
      { "crawler"   : {} },
      { "example"   : {} },
      { "publisher" : {} },
      { "web"       : {} }
                 ]
}

END_JSON
}

1;
