use Test::More tests => 3;
use HTML::Template::JIT;
my $debug = 0;

# test URL escapeing
$template = HTML::Template::JIT->new(
                                     filename => 'escape.tmpl',
                                     path => ['t/templates'],
                                     jit_path => 't/jit_path',
                                     jit_debug => $debug,
                                    );
$template->param(STUFF => '<>"\''); #"
$output = $template->output;
# print STDERR "-"x70, "\n", $output, "\n", "-"x70, "\n";
ok($output !~ /[<>"']/); #"

# test URL escapeing
$template = HTML::Template::JIT->new(
                                     filename => 'urlescape.tmpl',
                                     path => ['t/templates'],
                                     jit_path => 't/jit_path',
                                     jit_debug => $debug,
                                    );
$template->param(STUFF => '<>"; %FA'); #"
$output = $template->output;
ok($output !~ /[<>"]/); #"

# test non-filled escaped var
$template = HTML::Template::JIT->new(
                                     filename => 'urlescape.tmpl',
                                     path => ['t/templates'],
                                     jit_path => 't/jit_path',
                                     jit_debug => $debug,
                                    );
$output = $template->output;
like($output, qr/Some URL escaped stuff:/); 

