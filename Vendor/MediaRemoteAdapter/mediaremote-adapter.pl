#!/usr/bin/perl
# Copyright (c) 2025 Jonas van den Berg
# This file is licensed under the BSD 3-Clause License.

use strict;
use warnings;
use DynaLoader;

my ($library, $operation, @arguments) = @ARGV;
die "Usage: mediaremote-adapter.pl DYLIB get|send [COMMAND]\n"
  unless defined $library && defined $operation;

my $symbol;
if ($operation eq "get") {
  $ENV{MEDIAREMOTEADAPTER_OPTION_now} = "";
  $symbol = "adapter_get_env";
} elsif ($operation eq "send") {
  my $command = $arguments[0];
  die "Missing media command\n" unless defined $command && $command =~ /^\d+$/;
  $ENV{MEDIAREMOTEADAPTER_PARAM_adapter_send_0_command} = $command;
  $symbol = "adapter_send_env";
} else {
  die "Unsupported operation: $operation\n";
}

my $handle = DynaLoader::dl_load_file($library, 0)
  or die "Failed to load MediaRemote adapter: " . DynaLoader::dl_error() . "\n";
my $address = DynaLoader::dl_find_symbol($handle, $symbol)
  or die "Failed to find symbol '$symbol'\n";
my $function = DynaLoader::dl_install_xsub("main::$symbol", $address);
&$function();
