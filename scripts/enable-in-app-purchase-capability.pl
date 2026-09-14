#!/usr/bin/perl
use strict;
use warnings;

my $project_file = $ARGV[0] // "Kiwix.xcodeproj/project.pbxproj";
my $target_name = $ARGV[1] // "Kiwix";

open my $fh, "<", $project_file or die "Unable to read $project_file: $!\n";
local $/;
my $project = <$fh>;
close $fh;

my ($target_id) = $project =~ /^\t\t([A-F0-9]+) \/\* \Q$target_name\E \*\/ = \{\n\t\t\tisa = PBXNativeTarget;/m;
die "Unable to find target $target_name in $project_file\n" unless $target_id;

my $capability = <<'PBX';
						SystemCapabilities = {
							com.apple.InAppPurchase = {
								enabled = 1;
							};
						};
PBX
chomp $capability;

if ($project =~ /(\t\t\t\t\t\Q$target_id\E = \{\n)(.*?)(\t\t\t\t\t\};)/s) {
    my ($prefix, $body, $suffix) = ($1, $2, $3);
    $body =~ s/\t{6}SystemCapabilities = "\[\\"com\.apple\.InAppPurchase\\": \[\\"enabled\\": (?:true|1)\]\]";\n//g;

    if ($body =~ /\t{6}SystemCapabilities = \{\n/s) {
        if ($body !~ /com\.apple\.InAppPurchase/s) {
            $body =~ s/(\t{6}SystemCapabilities = \{\n)/$1\t\t\t\t\t\t\tcom.apple.InAppPurchase = {\n\t\t\t\t\t\t\t\tenabled = 1;\n\t\t\t\t\t\t\t};\n/s;
        }
    } else {
        $body = "$capability\n$body";
    }

    $project =~ s/(\t\t\t\t\t\Q$target_id\E = \{\n).*?(\t\t\t\t\t\};)/$prefix$body$suffix/s;
} else {
    my $entry = <<PBX;
					$target_id = {
$capability
					};
PBX
    $project =~ s/(TargetAttributes = \{\n)/$1$entry/s
        or die "Unable to find TargetAttributes in $project_file\n";
}

open my $out, ">", $project_file or die "Unable to write $project_file: $!\n";
print {$out} $project;
close $out;
