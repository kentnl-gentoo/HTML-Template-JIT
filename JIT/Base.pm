package HTML::Template::JIT::Base;

use 5.006;
use strict;
use warnings;

our $VERSION = '0.01';

sub param {
  my $pkg = shift;

  my ($param_hash, $param_map);
  {
    no strict 'refs';
    $param_map = \%{$pkg . '::param_map'};
    $param_hash = \%{$pkg . '::param_hash'};
  }

  # the no-parameter case - return list of parameters in the template.
  return keys(%$param_hash) unless scalar(@_);
  
  my $first = shift;
  my $type = ref $first;

  # the one-parameter case - could be a parameter value request or a
  # hash-ref.
  if (!scalar(@_) and !length($type)) {
    my $param = lc $first;
    return undef unless (exists($param_hash->{$param}) and
                         defined($param_map->{$param}));
    return $param_map->{$param};
  }

  if (!scalar(@_)) {
    croak("HTML::Template->param() : Single reference arg to param() must be a hash-ref!  You gave me a $type.")
      unless $type eq 'HASH' or 
        (ref($first) and UNIVERSAL::isa($first, 'HASH'));  
    push(@_, %$first);
  } else {
    unshift(@_, $first);
  }
  
  croak("HTML::Template->param() : You gave me an odd number of parameters to param()!")
    unless ((@_ % 2) == 0);

  # strangely, changing this to a "while(@_) { shift, shift }" type
  # loop causes perl 5.004_04 to die with some nonsense about a
  # read-only value.
  for (my $x = 0; $x < $#_; $x += 2) {
    my $name = lc $_[$x];
    my $value = $_[($x + 1)];
    
    # set the value
    $param_map->{$name} = $value;
  }
}

sub clear_params {
  my $pkg = shift;
  {
    no strict 'refs';
    %{$pkg . '::param_map'} = ();
  }
}

1;

__END__

=pod

=head1 NAME

HTML::Template::JIT::Base - base class for compiled templates

=head1 SYNOPSIS

  use base 'HTML::Template::JIT::Base';

=head1 DESCRIPTION

This module is used internally by HTML::Template::JIT as a base class
for compiled template modules.

=head1 AUTHOR

Sam Tregar <sam@tregar.com>

=head1 LICENSE

HTML::Template::JIT : Just-in-time compiler for HTML::Template

Copyright (C) 2001 Sam Tregar (sam@tregar.com)

This module is free software; you can redistribute it and/or modify it
under the terms of either:

a) the GNU General Public License as published by the Free Software
Foundation; either version 1, or (at your option) any later version,
or

b) the "Artistic License" which comes with this module.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See either
the GNU General Public License or the Artistic License for more details.

You should have received a copy of the Artistic License with this
module, in the file ARTISTIC.  If not, I'll be glad to provide one.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307
USA

