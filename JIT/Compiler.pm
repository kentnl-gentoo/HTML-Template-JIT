package HTML::Template::JIT::Compiler;

use 5.006;
use strict;
use warnings;

our $VERSION = '0.01';

use HTML::Template;
use Carp qw(croak confess);
use File::Path qw(mkpath rmtree);

sub compile {
  my %args = @_;
  my $self = bless({});

  # parse the template as usual
  $self->{template} = HTML::Template->new(%args);
  
  # setup state
  $self->{jit_path}     = $args{jit_path};
  $self->{package}      = $args{package};
  $self->{package_dir}  = $args{package_dir};
  $self->{package_path} = $args{package_path};
  $self->{jit_pool}     = [];
  $self->{jit_sym}      = 0;
  $self->{jit_debug}    = $args{jit_debug};

  # compile internal representation into a chunk of C code
  my @code = $self->_output();

  if ($self->{jit_debug}) {
    print STDERR "###################### CODE START ######################\n\n";
    open(INDENT, "| indent -kr > code.tmp");
    print INDENT join("\n", @code);
    close INDENT;
    open(CODE, 'code.tmp');
    print STDERR join('', <CODE>);
    close(CODE);
    unlink('code.tmp');    
    print STDERR "\n\n###################### CODE END ######################\n\n";
  }

  $self->_write_module(\@code);

  # try to load the module and return package handle if successful
  my $result;
  eval { $result = require $self->{package_path}; };
  return 1 if $result;

  # don't leave failed compiles lying around unless we're debuging
  rmtree($self->{package_dir}, 0, 0) unless $self->{jit_debug};
  die $@ if $@;
  return 0;
}

# writes out the module file
sub _write_module {
  my $self = shift;
  my $code = shift;

  # make directory
  mkpath($self->{package_dir}, 0, 0700);
  
  # open module file
  open(MODULE, ">$self->{package_path}") or die "Unable to open $self->{package_path} for output : $!";
  
  my $inline_debug = "";
  my $optimize = "-O3";
  if ($self->{jit_debug}) {
    $inline_debug = ", CLEAN_AFTER_BUILD => 0";
    $optimize = "-g";
  }

  # print out preamble
  print MODULE <<END;
package $self->{package};
use base 'HTML::Template::JIT::Base';

use Inline C => Config => OPTIMIZE => "$optimize", DIRECTORY => "$self->{package_dir}" $inline_debug;
use Inline C => <<CODE_END;

END

  # print out code
  print MODULE join("\n", @$code), "\nCODE_END\n";

  # output the param hash
  print MODULE "our \%param_hash = (\n", join(',', $self->_param_hash([])), ");\n";
  
  # empty param map
  print MODULE "our \%param_map;";

  print MODULE "\n1;\n";

  # all done
  close MODULE;
}

# construct the output function
sub _output {
  my $self = shift;
  my $template = $self->{template};

  # construct body of output
  my @code = $self->_output_template($template, "param_map");
  
  # setup result size based on gathered stats
  unshift @code, "SvGROW(result, $self->{text_size});";

  # output pool of variables used in body
  unshift @code, $self->_write_pool, '';

  # start code for output function  
  unshift @code, <<END;
SV * output(SV *self) { 
  SV *result = newSVpvn("", 0);
  HV *param_map = get_hv(\"$self->{package}::param_map\", 0);
  SV *temp_sv;
  SV **temp_svp;

END

  # finish output function
  push(@code, "return result;", "}");
  
  return @code;
}

# output the body of a single template
sub _output_template {
  my $self = shift;
  my $template = shift;
  my $param_map_hv = shift;

  my @code;

  # setup some convenience aliases ala HTML::Template::output()
  use vars qw($line  @parse_stack  %param_map); 
  local      (*line, *parse_stack, *param_map);
  *parse_stack = $template->{parse_stack};
  *param_map   = $template->{param_map};

  my %reverse_param_map = map { $param_map{$_} => $_ } keys %param_map;

  my $type;
  my $parse_stack_length = $#parse_stack;
  my $text_size = 0;
  
  my %labels;

  for (my $x = 0; $x <= $parse_stack_length; $x++) {
    *line = \$parse_stack[$x];
    $type = ref($line);
    
    # need a jump label for this line?
    if ($labels{$x}) {
      push(@code, "$labels{$x}:");
    }

    if ($type eq 'SCALAR') {
      # append string and add size to text_size counter
      push @code, _concat_string($$line);
      $self->{text_size} += length $$line;

    } elsif ($type eq 'HTML::Template::VAR') {
      # append the var
      push @code, _concat_var($reverse_param_map{$line}, $param_map_hv);
      
    } elsif ($type eq 'HTML::Template::LOOP') {
      # get loop template
      my $loop_template = $line->[HTML::Template::LOOP::TEMPLATE_HASH]{$x};

      # allocate an hv for the loop param_map
      my $loop_param_map_hv = $self->_get_var("HV *");

      # output the loop start
      push @code, $self->_start_loop($reverse_param_map{$line}, $param_map_hv, 
				     $loop_param_map_hv);

      # output the loop body
      push @code, $self->_output_template($loop_template, $loop_param_map_hv);
      
      # send the loop
      push @code, $self->_end_loop();

    } elsif ($type eq 'HTML::Template::COND') {
      # if, unless and else

      # get a label to jump to
      my $label = $self->_get_label;
      
      # store label for output
      $labels{$line->[HTML::Template::COND::JUMP_ADDRESS]} = $label;

      # output conditional
      push(@code, $self->_cond($line->[HTML::Template::COND::JUMP_IF_TRUE], 
			       $line->[HTML::Template::COND::VARIABLE_TYPE] == HTML::Template::COND::VARIABLE_TYPE_VAR,
			       $reverse_param_map{$line->[HTML::Template::COND::VARIABLE]},
			       $label,
			       $param_map_hv
			      ));

    } elsif ($type eq 'HTML::Template::NOOP') {
      # noop
    } else {
      confess("Unsupported object type in parse stack : $type");
    }
  }


  return @code;
}

# output a conditional jump to $label
sub _cond {
  my ($self, $is_unless, $is_var, $name, $label, $param_map_hv) = @_;
  my $name_string = _quote_string($name);
  my $name_len = length($name);
  my @code;
  
  push @code, "temp_svp = hv_fetch($param_map_hv, \"$name_string\", $name_len, 0);";
  
  if ($is_var) {
    if ($is_unless) {
      # unless
      push(@code, "if (temp_svp && SvTRUE(*temp_svp)) goto $label;");
    } else {
      # if
      push(@code, "if (!temp_svp || !SvTRUE(*temp_svp)) goto $label;");
    }
  } else {
    if ($is_unless) {
      # unless
      push(@code, "if (temp_svp && *temp_svp != &PL_sv_undef && av_len((AV *) SvRV(*temp_svp)) > -1) goto $label;");
    } else {
      # if
      push(@code, "if (!temp_svp || *temp_svp == &PL_sv_undef || av_len((AV *) SvRV(*temp_svp)) == -1) goto $label;");
    }
  }

  return @code;
}

# start a loop
sub _start_loop {
  my ($self, $name, $param_map_hv, $loop_param_map_hv) = @_;
  my $name_string = _quote_string($name);
  my $name_len = length($name_string);
  my $av = $self->_get_var("AV *");
  my $av_len = $self->_get_var("I32");
  my $counter = $self->_get_var("I32");

  return <<END;
temp_svp = hv_fetch($param_map_hv, "$name_string", $name_len, 0);
if (temp_svp && (*temp_svp != &PL_sv_undef)) {
   if (!SvROK(*temp_svp) || SvTYPE($av = (AV *) SvRV(*temp_svp)) != SVt_PVAV)
      croak("Bad param settings - found non array-ref for loop $name_string!");  
   $av_len = av_len($av);

   for($counter = 0; $counter <= $av_len; $counter++) {
      temp_svp = av_fetch($av, $counter, 0);
      if (!temp_svp || !SvROK(*temp_svp) || SvTYPE($loop_param_map_hv = (HV *) SvRV(*temp_svp)) != SVt_PVHV)
        croak("Bad param settings - found non hash-ref for loop row in loop $name_string!");

END
}

# end a loop
sub _end_loop {
  return '}}';
}

# construct %param_hash
sub _param_hash {
  my ($self, $path) = @_;
  my $template = $self->{template};

  my @params;
  if (@$path) {
    @params = $template->query(LOOP => $path);
  } else {
    @params = $template->param();
  }

  my @out;
  foreach my $name (@params) {
    my $type = $template->query(name => [ @$path, $name ]);
    if ($type eq 'VAR') {
      push @out, "'$name'", 1;
    } else {
      push @out, "'$name'", "\n{" . join(', ', $self->_param_hash([ @$path, $name ])) . "\n}\n";
    }
  }
	 
  return @out;
}


# get a fresh var of the requested C type from the pool
sub _get_var {
  my ($self, $type) = @_;
  my $pool = $self->{jit_pool};
  my $sym = "sym_" . $self->{jit_sym}++;
  push @$pool, $type, $sym;
  return $sym;
}

# write out the code to initialize the pool
sub _write_pool {
  my ($self, $type) = @_;
  my $pool = $self->{jit_pool};
  
  my @code;

  for (my $index = 0; $index < @$pool; $index += 2) {
    push(@code, $pool->[$index] . ' ' . $pool->[$index + 1] . ";");
  }

  return @code;
}

# get a unique label
sub _get_label {
  my $self = shift;
  return "label_" . $self->{jit_sym}++;
}

# concatenate a string onto result
sub _concat_string {
  return "" unless $_[0];
  my $len = length($_[0]);
  my $string = _quote_string($_[0]);

  return <<END;
sv_catpvn(result, "$string", $len);
END

}

# concatenate a var onto result
sub _concat_var {
  my ($name, $hv) = @_;
  my $string = _quote_string($name);
  my $len = length($name);

  return <<END;
temp_svp = hv_fetch($hv, "$string", $len, 0);
if (temp_svp && (*temp_svp != &PL_sv_undef)) sv_catsv(result, *temp_svp);
END

}

# turn a string into something that C will accept inside
# double-quotes.  or should I go the array of bytes route?  I think
# that might be the only way to get UTF-8 working.  It's such hell to
# debug though...
sub _quote_string {
  $_[0] =~ s/\\/\\\\/g;
  $_[0] =~ s/"/\\\\"/g;
  $_[0] =~ s/\r/\\\\r/g;
  $_[0] =~ s/\n/\\\\n/g;
  $_[0] =~ s/\t/\\\\t/g;
  return $_[0];
}  

1;

__END__

=pod

=head1 NAME
HTML::Template::JIT::Compiler - Compiler for HTML::Template::JIT

=head1 SYNOPSIS

  use HTML::Template::JIT::Compiler;

  HTML::Template::JIT->compile(...); 

=head1 DESCRIPTION

This module is used internally by HTML::Template::JIT to compile
template files.  Don't use it directly - use HTML::Template::JIT
instead.

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

