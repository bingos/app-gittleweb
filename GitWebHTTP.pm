package GitWebHTTP;

#ABSTRACT: Simple HTTP server for serving gitweb.cgi

use strict;
use warnings;
use Cwd ();
use Pod::Usage;
use HTTP::Daemon;
use HTTP::Status;
use HTTP::Response;
use HTTP::Request::AsCGI;
use File::Spec;
use URI::Escape;
use POSIX qw[strftime :sys_wait_h];
use Getopt::Long;
use IO::Handle;

my $loghandle;

sub run {
  my $root = Cwd::getcwd();
  my $port = '8080';
  my $conf;
  my $logfile;

  GetOptions(
    "root=s", \$root,
    "port=i", \$port,
    "config=s", \$conf,
    "logfile=s", \$logfile,
  );

  Cwd::chdir( $root ) or die "$!\n";

  $ENV{GITWEB_CONFIG} = $conf if $conf && -e $conf;

  if ( $logfile ) {
    open $loghandle, '>>', $logfile or die "Could not open '$logfile', sorry: $!\n";
    $loghandle->autoflush(1);
  }

  local $SIG{CHLD};

  sub _REAPER {
    my $child;
    while (($child = waitpid(-1,WNOHANG)) > 0) {}
    $SIG{CHLD} = \&_REAPER; # still loathe SysV
  };

  $SIG{CHLD} = \&_REAPER;

  my $httpd = HTTP::Daemon->new( LocalPort => $port )
                or die "$!\n";

  while ( 1 ) {
    my $conn = $httpd->accept;
    next unless $conn;
    my $child = fork();
    unless ( defined $child ) {
      die "Cannot fork child: $!\n";
    }
    if ( $child == 0 ) {
      _handle_request( $conn, $root );
      exit(0);
    }
    $conn->close();
  }

}

sub _handle_request {
  my $conn = shift;
  my $root = shift;
  REQ: while (my $req = $conn->get_request) {
    print $loghandle join("\t",time(),$conn->peerhost(),$req->uri->path_query), "\n";
    if ($req->method eq 'GET' ) {
      my @path = $req->uri->path_segments;
      my $path = File::Spec->catfile( $root, @path );
      if ( $req->uri->path =~ m#^/gitweb\.cgi# ) {
        my $c = HTTP::Request::AsCGI->new(
          $req,
          'SCRIPT_NAME', '/gitweb.cgi',
          'SCRIPT_FILENAME', '/home/ec2-user/web/gitweb.cgi'
        )->setup;
        local $ENV{'PATH_INFO'} = uri_unescape( $ENV{'PATH_INFO'} );
        local $ENV{'REQUEST_URI'} = uri_unescape( $ENV{'REQUEST_URI'} );
        local $ENV{'REMOTE_ADDR'} = $conn->peerhost();
        local $ENV{'REMOTE_HOST'} = $ENV{'REMOTE_ADDR'};
        local $ENV{'REMOTE_PORT'} = $conn->peerport();
        eval {
          do 'gitweb.cgi';
        };
        warn $@ if $@;
        $c->restore;
        my $resp = $c->response;
        $conn->send_response( $resp );
        next REQ;
      }
      unless ( -e $path ) {
        $conn->send_error(RC_NOT_FOUND);
        next REQ;
      }
      $conn->send_file_response( $path );
    }
    else {
      $conn->send_error(RC_FORBIDDEN)
    }
  }
}

q[Gittle flittle];
