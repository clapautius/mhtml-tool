#!/usr/bin/perl -w

use strict;

=pod

=head1 NAME

B<unmht> - Unpack a MIME HTML archive


=head1 SYNOPSIS

B<unmht> unpacks MIME HTML archives that some browsers (such as Opera) save
by default.  The file extensions of such archives are .mht or .mhtml.

The first HTML file in the archive is taken to be the primary web page, the
other contained files for "page requisites" such as images or frames.  The
primary web page is written to the output directory (the current directory by
default), the requisites to a subdirectory named after the primary HTML file
name without extension, with "_files" appended.  Link URLs in all HTML
files referring to requisites are rewritten to point to the saved files.


=head1 OPTIONS

=over

=item B<-h>, B<-?>, B<--help>

Print a brief usage summary.

=item B<-l>, B<--list>

List archive contents instead of unpacking.  Four columns are output: file
name, MIME type, size and URL.  Unavailable entries are replaced by "(?)".

=item B<-o> I<directory/ or name>, B<--output> I<directory/ or name>

If the argument ends in a slash or is an existing directory, unpack to that
directory instead of current directory.  Otherwise the argument is taken as a
path to the file name to write the primary HTML file to.  If the output
directory does not exist, it is created.

=back


=head1 SEE ALSO

http://www.volkerschatz.com/unix/uware/unmht.html

http://www.loganowen.com/mht-rip/

http://sourceforge.net/projects/mhtconv/


=head1 COPYLEFT

B<unmht> is Copyright (c) 2012 Volker Schatz.  It may be copied and/or
modified under the same terms as Perl.

=cut

use File::Path;
use File::Copy;
use File::Glob;
use URI;
use MIME::Base64;
use MIME::QuotedPrint;
use HTML::PullParser;
use HTML::Tagset;
use Getopt::Long;


# Add approriate ordinal suffix to a number.
# -> Number
# <- String of number with ordinal suffix
sub ordinal
{
    return $_[0]."th" if $_[0] > 3 && $_[0] < 20;
    my $unitdig= $_[0] % 10;
    return $_[0]."st" if $unitdig == 1;
    return $_[0]."nd" if $unitdig == 2;
    return $_[0]."rd" if $unitdig == 3;
    return $_[0]."th";
}


{
my %taken;

# Find unique file name.
# -> Preferred file name, or undef
#    MHT archive name (as a fallback if no name given)
# <- File name not conflicting with names returned by previous calls, but which
#    may exist!
sub unique_name
{
    my ($fname, $mhtname)= @_;
    my ($trunc, $ext);

    if( defined $fname ) {
        $fname =~ s/^\s+//;
        $fname =~ s/\s+$//;
        $taken{$fname}= 1, return $fname unless $taken{$fname};
        ($trunc, $ext)= $fname =~ /^(.*?)(\.\w+)?$/;
        $ext //= "";
    }
    else {
        $trunc= $mhtname || "unpack";
        $trunc =~ s/\.mht(?:ml?)?$//i;
        $ext= "";
    }
    for my $suff (1..9999) {
        $fname= "${trunc}_$suff$ext";
        $taken{$fname}= 1, return $fname unless $taken{$fname};
        ++$suff;
    }
    return undef;
}

}


# Output error message and exit with return value 1.
sub abort
{
    print STDERR "$_[0]\n";
    exit 1;
}


# Generate output file directories and primary HTML file name depending on
# --output option and primary HTML file name from archive.  In case the primary
# HTML file is not the first file in the archive, the secondary files directory
# is renamed or the files moved on the second call, when the primary HTML file
# name is known.
# -> Value of --output option (or  undef)
#    Primary HTML file name from MHT archive
#    Flag indicating if .._files subdirectory should be created
#    Hash reference to store resulting paths to
sub mkfiledir
{
    my ($outputopt, $firsthtmlname, $needfilesdir, $out)= @_;

    my $prevfilespath= $$out{filespath};
    $firsthtmlname= "unpackmht-$$" unless defined $firsthtmlname;
    if( ! defined $outputopt ) {
        $$out{toppath}= ".";
    }
    elsif( -d $outputopt || $outputopt =~ m!/$! ) {
        $$out{toppath}= $outputopt;
    }
    else {
        ($$out{toppath}, $firsthtmlname)= $outputopt =~ m!^(.*/)?([^/]+)$!;
        abort "Empty output file name." unless defined $firsthtmlname;
        $firsthtmlname .= ".html" unless $firsthtmlname =~ /\./;
        $$out{toppath}= "." unless defined $$out{toppath};
    }
    $$out{toppath} =~ s!/$!!;
    $$out{firstout}= "$$out{toppath}/$firsthtmlname";
    $$out{filesdir}= $firsthtmlname;
    $$out{filesdir} =~ s/\.[^.]+$//;
    $$out{filesdir} .= "_files";
    $$out{filespath}= "$$out{toppath}/$$out{filesdir}";
    if( defined $prevfilespath ) {
        return unless $prevfilespath ne $$out{filespath};
        return unless -d $prevfilespath;
        if( ! -d $$out{filespath} ) {
            File::Copy::move($prevfilespath, $$out{filespath})
                or abort "Could not rename secondary files directory.";
        }
        else {
            for (File::Glob::bsd_glob("$prevfilespath/*")) {
                File::Copy::move($_, $$out{filespath})
                    or abort "Could not move secondary files.";
            }
        }
    }
    else {
        my $createall= $needfilesdir ? $$out{filespath} : $$out{toppath};
        if( ! -d $createall ) {
            File::Path::make_path($createall) or abort "Could not create output directory $createall.";
        }
    }
}


my %opt;
my @optdescr= ( 'output|o=s', 'list|l!', 'help|h|?!' );
my %config;

my $status= GetOptions(\%opt, @optdescr);


if( !$status || $opt{help} ) {
    print <<EOF;
Usage: unmht [ -l | --list | -o <dir/ or name> | --output <dir/ or name> ] <MHT file>
By default, unpacks an MHT archive (an archive type saved by some browsers) to
the current directory.  The first HTML file in the archive is taken for the
primary web page, and all other contained files are written to a directory
named after that HTML file.  Options:
-l, --list    List archive contents (file name, MIME type, size and URL)
-o, --output  Unpack to directory <dir/> or to file <name>.html
Use the command "pod2man unmht > unmht.1" or
"pod2html unmht > unmht.html" to extract the manual.
EOF
    exit !$status;
}

my $firstline= <>;

$firstline =~ m!Content-Type: multipart/related;.* boundary=(.*)$!
    or abort "Can't find Content-Type header - not a MIME HTML file?";

my $boundary= $1;
my $endcode= $boundary;
$endcode =~ s/\s+$//;
my %by_url;
my @htmlfiles;
my $fh;

{
    $/= "\n--$boundary\n";
    <>;
    my $fileind= 1;
    while( defined( my $data= <> ) ) {
        my %headers;
        while( $data =~ s/^([-\w]+): (.*)\n// ) {
            $headers{$1}= $2;
        }
        $data =~ s/^\n//;
        $data =~ s/\n--$endcode--\r?\n$/\n/s;
        my ($type, $origname);
        if( defined($headers{"Content-Type"}) && $headers{"Content-Type"} =~ /\bname=([^;]*)/ ) {
            $origname= $1;
            ($type)= $headers{"Content-Type"} =~ /^(\w+\/\w+)\b/;
            $type //= "";
        }
        elsif( defined($headers{"Content-Disposition"}) && $headers{"Content-Disposition"} =~ /\bfilename=([^;]*)/ ) {
            $origname= $1;
            $type= $origname =~ /\.html?$/i ? "text/html" : "";
        }
        elsif( defined($headers{"Content-Location"}) ) {
            $origname= $headers{"Content-Location"};
            $origname =~ s!^.*/!!;
            $type= "";
        }
        my $fname= unique_name($origname, $ARGV[0]);
        if( !defined($headers{"Content-Transfer-Encoding"}) ) {
            print STDERR "Warning: Encoding of ", ordinal($fileind), " file not found - leaving as-is.\n";
        }
        elsif( $headers{"Content-Transfer-Encoding"} =~ /\bbase64\b/i ) {
            $data= MIME::Base64::decode($data);
        }
        elsif( $headers{"Content-Transfer-Encoding"} =~ /\bquoted-printable\b/i ) {
            $data= MIME::QuotedPrint::decode($data);
        }
        if( $opt{list} ) {
            $origname =~ s/\s+$// if defined $origname;
            my $size= length($data);
            print $fname // "(?)", "\t", $type || "(?)", "\t$size\t",
                    $headers{"Content-Location"} // "(?)", "\n";
            next;
        }
        $headers{fname}= $fname;
        if( $headers{"Content-Location"} ) {
            $headers{url}= $headers{"Content-Location"};
            $headers{url} =~ s/\s+$//;
            $by_url{$headers{url}}= \%headers;
        }
        if( $type eq "text/html" ) {
            $headers{data}= $data;
            push @htmlfiles, \%headers;
        }
        else {
            mkfiledir($opt{output}, $htmlfiles[0]->{fname}, 1, \%config);
            $fname= "$config{filespath}/$fname";
            open $fh, ">$fname" or abort "Could not create file $fname.";
            print $fh $data;
            close $fh;
        }
    }
    continue { ++$fileind; }
}


mkfiledir($opt{output}, $htmlfiles[0]->{fname}, 0, \%config);

my $filesprefix= $config{filesdir} . "/";
my $outname= $config{firstout};
print "primary html output name: $outname\n";

for my $html (@htmlfiles) {
    my $linksubst= "";
    my $p= HTML::PullParser->new( doc => \$html->{data}, "start" => 'text, attr, tagname', "text" => 'text', "end" => 'text' );
    while( defined( my $tok= $p->get_token()) ) {
        my $linkary;
        my @linkattrs;
        if( ref($tok->[1]) && ($linkary= $HTML::Tagset::linkElements{$tok->[2]})
                && (@linkattrs= grep $tok->[1]->{$_}, @$linkary) ) {
            for my $attr (@linkattrs) {
                my $uri= URI->new($tok->[1]->{$attr});
                $uri= $uri->abs($html->{url});
                $tok->[1]->{$attr}= "$filesprefix" . $by_url{$uri->as_string()}->{fname}
                    if $by_url{$uri->as_string()};
            }
            delete $tok->[1]->{"/"};
            $linksubst .= "<$tok->[2] " . join(" ", map("$_=\"$tok->[1]->{$_}\"", keys %{$tok->[1]})) . ">";
        }
        else {
            $linksubst .= $tok->[0];
        }
    }
    $outname= "$config{filespath}/$html->{fname}" unless defined $outname;
    open $fh, ">$outname" or abort "Could not create file $outname.";
    print $fh $linksubst;
    close $fh;
    # for all except the first HTML file:
    $filesprefix= "";
    $outname= undef;
}
