package npg_pipeline::archive::file::generation::seq_alignment;

use Moose;
use Carp;
use English qw{-no_match_vars};
use Readonly;
use Moose::Meta::Class;
use Try::Tiny;
use File::Slurp;
use JSON::XS;
use List::Util qw(sum);
use List::MoreUtils qw(any);
use open q(:encoding(UTF8));

use npg_tracking::data::reference::find;
use npg_tracking::data::transcriptome;
use npg_tracking::data::bait;
use npg_pipeline::lsf_job;
use npg_common::roles::software_location;
use st::api::lims;
extends q{npg_pipeline::base};

our $VERSION  = '0';

Readonly::Scalar our $DNA_ALIGNMENT_SCRIPT         => q{bam_alignment.pl};
Readonly::Scalar our $NUM_SLOTS                    => q(12,16);
Readonly::Scalar our $MEMORY                       => q{32000}; # memory in megabytes
Readonly::Scalar our $FORCE_BWAMEM_MIN_READ_CYCLES => q{101};
Readonly::Scalar my  $QC_SCRIPT_NAME               => q{qc};

=head2 phix_reference

A path to phix reference for bwa alignment to split phiX spike-in reads

=cut
has 'phix_reference' => (isa => 'Str',
                         is => 'rw',
                         required => 0,
                         lazy_build => 1,
);
sub _build_phix_reference {
   my $self = shift;

   my $ruser = Moose::Meta::Class->create_anon_class(
     roles => [qw/npg_tracking::data::reference::find/]
   )->new_object({
     species => q{PhiX},
     aligner => q{fasta},
     ($self->repository ? (q(repository)=>$self->repository) : ())
   });

   my $phix_ref;
   eval {
      $phix_ref = $ruser->refs->[0];
      1;
   } or do{
      carp $EVAL_ERROR;
   };

   return $phix_ref;
}

has q{_AlignmentFilter_jar} => (
                           isa        => q{NpgCommonResolvedPathJarFile},
                           is         => q{ro},
                           coerce     => 1,
                           default    => q{AlignmentFilter.jar},
                                );

has q{_SplitBamByChromosomes_jar} => (
                           isa        => q{NpgCommonResolvedPathJarFile},
                           is         => q{ro},
                           coerce     => 1,
                           default    => q{SplitBamByChromosomes.jar},
                                );

has 'input_path'      => ( isa        => 'Str',
                           is         => 'ro',
                           lazy_build => 1,
                         );
sub _build_input_path {
  my $self = shift;
  return $self->recalibrated_path();
}

has 'job_name_root'  => ( isa        => 'Str',
                           is         => 'ro',
                           lazy_build => 1,
                         );
sub _build_job_name_root {
  my $self = shift;
  return join q{_}, q{seq_alignment},$self->id_run(),$self->timestamp();
}

has '_job_args'   => ( isa     => 'HashRef',
                       is      => 'ro',
                       default => sub { return {};},
                     );

has '_using_alt_reference' => ( isa => 'Bool',
                                is  => 'rw',
                                default => 0,
                              );

sub generate {
  my ( $self, $arg_refs ) = @_;

  my (@lanes) = $self->positions($arg_refs);
  if ( ref $lanes[0] && ref $lanes[0] eq q{ARRAY} ) {   @lanes = @{ $lanes[0] }; }

  $self->_generate_command_arguments(\@lanes);

  my @job_indices = keys %{$self->_job_args};
  if (!@job_indices) {
    $self->debug('Nothing to do');
    return ();
  }

  my $job_id = $self->submit_bsub_command(
    $self->_command2submit($arg_refs->{required_job_completion})
  );
  $self->_save_arguments($job_id);

  return ($job_id);
}

sub _command2submit {
  my ($self, $required_job_completion) = @_;

  $required_job_completion ||= q{};
  my $outfile = join q{/} , $self->make_log_dir( $self->archive_path() ), $self->job_name_root . q{.%I.%J.out};
  my @job_indices = sort {$a <=> $b} keys %{$self->_job_args};
  my $job_name = q{'} . $self->job_name_root . npg_pipeline::lsf_job->create_array_string(@job_indices) . q{'};
  my $resources = ( $self->fs_resource_string( {
      counter_slots_per_job => 4,
      resource_string => $self->_default_resources(),
    } ) );
  return  q{bsub -q } . $self->lsf_queue()
    .  q{ } . $self->ref_adapter_pre_exec_string()
    . qq{ $resources $required_job_completion -J $job_name -o $outfile}
    .  q{ 'perl -Mstrict -MJSON -MFile::Slurp -Mopen='"'"':encoding(UTF8)'"'"' -e '"'"'exec from_json(read_file shift@ARGV)->{shift@ARGV} or die q(failed exec)'"'"'}
    .  q{ }.(join q[/],$self->input_path,$self->job_name_root).q{_$}.q{LSB_JOBID}
    .  q{ $}.q{LSB_JOBINDEX'} ;
}

sub _save_arguments {
  my ($self, $job_id) = @_;
  my $file_name = join q[_], $self->job_name_root, $job_id;
  $file_name = join q[/], $self->input_path, $file_name;
  write_file($file_name, encode_json $self->_job_args);

  $self->debug(qq[Arguments written to $file_name]);

  return $file_name;
}

sub _lsf_alignment_command { ## no critic (Subroutines::ProhibitExcessComplexity)
  my ( $self, $l, $is_plex ) = @_;

  $is_plex ||= 0;
  my $id_run = $self->id_run;
  my $position = $l->position;
  my $name_root = $id_run . q{_} . $position;
  my $tag_index;
  my $spike_tag;
  my $input_path= $self->input_path;
  my $archive_path= $self->archive_path;
  my $qcpath= $self->qc_path;
  if($is_plex) {
    $tag_index = $l->tag_index;
    $spike_tag = (defined $l->spiked_phix_tag_index and $l->spiked_phix_tag_index == $tag_index);
    $name_root .= q{#} . $tag_index;
    $input_path  .= qq{/lane$position};
    $archive_path = $self->lane_archive_path($position);
    $qcpath       = $self->lane_qc_path($position);
  }

  if (1 < sum $l->contains_nonconsented_xahuman,
      $l->separate_y_chromosome_data,
      $l->contains_nonconsented_human) {
    $self->logcroak(q{Only one of nonconsented X and autosome human split, },
                    q{separate Y chromosome data and nonconsented human split },
                    qq{may be specified ($name_root)});
  }
  if (($l->contains_nonconsented_xahuman or $l->separate_y_chromosome_data) and
      not $l->reference_genome=~/Homo_sapiens/smx) {
    $self->logcroak(q{Nonconsented X and autosome human split, },
                    q{and separate Y chromosome data, },
                    qq{must have Homo sapiens reference ($name_root)});
  }
  if ($l->contains_nonconsented_human and
      $l->reference_genome and
      $l->reference_genome=~/Homo_sapiens/smx ) {
    $self->logcroak(q{Nonconsented human split must not have Homo sapiens },
                    qq{reference ($name_root)});
  }
  my $do_rna = $self->_do_rna_analysis($l);

   # when no target alignment - splice out unneeded p4 nodes, add -x flag to scramble,
   #  unset the reference for bam_stats and amend the AlignmentFilter command
   my $no_tgtaln_splice_flag = q[];
   my $scramble_reference_unset = q[];
   my $stats_reference_unset = q[];
   my $af_target_in_flag = q[];
   my $af_unaln_out_flag_name = q[];
   if(not $self->_ref($l,q(fasta)) or not $l->alignments_in_bam) {
     $no_tgtaln_splice_flag = q[-splice_nodes '"'"'src_bam:-alignment_filter:__PHIX_BAM_IN__'"'"'];
     $scramble_reference_unset = q[-keys scramble_reference_flag -vals '"'"'-x'"'"'];
     $stats_reference_unset = q[-nullkeys stats_reference_flag]; # both samtools and bam_stats
     $af_target_in_flag = q[-nullkeys af_target_in_flag]; # switch off AlignmentFilter target input
     $af_unaln_out_flag_name = q[-keys af_target_out_flag_name -vals '"'"'UNALIGNED'"'"']; # rename "target output" flag
   }

   my $hs_bwa = ($self->is_paired_read ? 'bwa_aln' : 'bwa_aln_se');
   # continue to use the "aln" algorithm from bwa for these older chemistries (where read length <= 100bp) unless GCLP
   my $bwa = ($self->gclp or $self->is_hiseqx_run or $self->_has_newer_flowcell or any {$_ >= $FORCE_BWAMEM_MIN_READ_CYCLES } $self->read_cycle_counts)
             ? 'bwa_mem'
             : $hs_bwa;

   # There will be a new exception to the use of "aln": if you specify a reference
   # with alt alleles e.g. GRCh38_full_analysis_set_plus_decoy_hla, then we will use
   # bwa's "mem"
   $bwa = $self->_is_alt_reference($l) ? 'bwa_mem' : $bwa;

   my $human_split = $l->contains_nonconsented_xahuman ? q(xahuman) :
                     $l->separate_y_chromosome_data    ? q(yhuman) :
                     q();

   my $do_target_alignment = ($self->_ref($l,q(fasta)) and $l->alignments_in_bam);
   my $nchs = $l->contains_nonconsented_human;
   my $nchs_template_label = q{};
   if($nchs) {
     $nchs_template_label = q{humansplit_};
     if(not $do_target_alignment) {
       $nchs_template_label .= q{notargetalign_};
     }
   }

   my $nchs_outfile_label = $nchs? q{human}: q{};

   #TODO: allow for an analysis genuinely without phix and where no phiX split work is wanted - especially the phix spike plex....
  #TODO: support these various options below in P4 analyses
  if ((not $self->is_paired_read) and ($do_rna or $nchs)) {
    $self->logcroak(qq{only paired reads supported for RNA or non-consented human ($name_root)});
  }

   $self->info(q[Using p4]);
  if($l->contains_nonconsented_human) {
      $self->info(q[  nonconsented_humansplit])
  }
  if(not $self->is_paired_read) {
    $self->info(q[  single-end])
  }
  $self->info(q[  do_target_alignment is ],
              ($do_target_alignment? q[true]: q[false]));
  $self->info(q[  Using p4 template alignment_wtsi_stage2_],
              $nchs_template_label, q[template.json]);

   return join q( ), q(bash -c '),
                        q(mkdir -p), (join q{/}, $self->archive_path, q{tmp_$}.q{LSB_JOBID}, $name_root) ,q{;},
                        q(cd), (join q{/}, $self->archive_path, q{tmp_$}.q{LSB_JOBID}, $name_root) ,q{&&},
                        q(vtfp.pl),
                          q{-keys samtools_executable -vals samtools1},
                          q{-keys cfgdatadir -vals $}.q{(dirname $}.q{(readlink -f $}.q{(which vtfp.pl)))/../data/vtlib/},
                          q(-keys aligner_numthreads -vals `npg_pipeline_job_env_to_threads`),
                          q(-keys br_numthreads_val -vals `npg_pipeline_job_env_to_threads --exclude 1 --divide 2`),
                          q(-keys b2c_mt_val -vals `npg_pipeline_job_env_to_threads --exclude 2 --divide 2`),
                          q(-keys indatadir -vals), $input_path,
                          q(-keys outdatadir -vals), $archive_path,
                          q(-keys af_metrics -vals), $name_root.q{.bam_alignment_filter_metrics.json},
                          q(-keys rpt -vals), $name_root,
                          ($do_target_alignment? (q(-keys reference_dict -vals), $self->_ref($l,q(picard)).q(.dict)): ()),
                          ($nchs? (q(-keys reference_dict_hs -vals),
                                   $self->_default_human_split_ref(q{picard}, $self->repository),): ()),   # always human default
                          ($do_target_alignment? (q(-keys reference_genome_fasta -vals), $self->_ref($l,q(fasta)),): ()),
                          ($nchs? (q(-keys hs_reference_genome_fasta -vals),
                                   $self->_default_human_split_ref(q{fasta}, $self->repository)): ()),   # always human default
                          q(-keys phix_reference_genome_fasta -vals), $self->phix_reference,
                          q(-keys alignment_filter_jar -vals), $self->_AlignmentFilter_jar,
                          ($self->_do_bait_stats_analysis($l) ? (
                              q(-keys bait_regions_file -vals), $self->_bait($l)->bait_intervals_path(),
                              q(-prune_nodes '"'"'fopphx_samtools_stats_F0.*00_bait.*'"'"'),
                          ) : ( ## wildcard prune 
                              q(-prune_nodes '"'"'fop.*samtools_stats_F0.*00_bait.*'"'"'),
                          )),
                          ( $do_rna ? (
                               ($do_target_alignment? (q(-keys alignment_reference_genome -vals), $self->_ref($l,q(bowtie2)),): ()),
                                       ($nchs? (q(-keys hs_alignment_reference_genome -vals),
                                                $self->_default_human_split_ref(q{bowtie2}, $self->repository)): ()),   # always human default
                               q(-keys library_type -vals), ( $l->library_type =~ /dUTP/smx ? q(fr-firststrand) : q(fr-unstranded) ),
                               q(-keys transcriptome_val -vals), $self->_transcriptome($l)->transcriptome_index_name(),
                               q(-keys alignment_method -vals tophat2),
                               ($nchs ? q(-keys alignment_hs_method -vals tophat2) : ()),
                            ) : (
                               ($do_target_alignment? (q(-keys alignment_reference_genome -vals), $self->_ref($l,q(bwa0_6)),): ()),
                                 ($nchs? (q(-keys hs_alignment_reference_genome -vals),
                                          $self->_default_human_split_ref(q{bwa0_6}, $self->repository)): ()),   # always human default
                               q(-keys bwa_executable -vals bwa0_6),
                               q(-keys alignment_method -vals), $bwa,
                               ($nchs ? qq(-keys alignment_hs_method -vals $hs_bwa) : ()),
                          ) ),
                          (not $self->is_paired_read) ? q(-nullkeys bwa_mem_p_flag) : (),
                          $human_split ? qq(-keys final_output_prep_target_name -vals split_by_chromosome -keys split_indicator -vals _$human_split) : (),
                          $l->separate_y_chromosome_data ? (q(-keys split_bam_by_chromosome_flags -vals S=Y -keys split_bam_by_chromosome_flags -vals V=true -keys split_bam_by_chromosomes_jar -vals ), $self->_SplitBamByChromosomes_jar) : (),
                          (grep {$_} #avoid variable whitespace
                            $no_tgtaln_splice_flag, $scramble_reference_unset, $stats_reference_unset, $af_target_in_flag, $af_unaln_out_flag_name, # empty unless no target alignment
                          ),
                          q{$}.q{(dirname $}.q{(dirname $}.q{(readlink -f $}.q{(which vtfp.pl))))/data/vtlib/alignment_wtsi_stage2_}.$nchs_template_label.q{template.json},
                          qq(> run_$name_root.json),
                        q{&&},
                        qq(viv.pl -s -x -v 3 -o viv_$name_root.log run_$name_root.json ),
                        q{&&},
			_qc_command('bam_flagstats', $archive_path, $qcpath, $l, $is_plex),
                        q{&&},
                        _qc_command('bam_flagstats', $archive_path, $qcpath, $l, $is_plex, 'phix'),
                        q{&&},
                        $human_split ? join q( ),
                          _qc_command('bam_flagstats', $archive_path, $qcpath, $l, $is_plex, $human_split),
                        q{&&} : q(),
                        $nchs        ? join q( ),
                          _qc_command('bam_flagstats', $archive_path, $qcpath, $l, $is_plex, $nchs_outfile_label),
                          q{&&} : q(),
                        _qc_command('alignment_filter_metrics', undef, $qcpath, $l, $is_plex),
                      q(');
}

sub _qc_command {##no critic (Subroutines::ProhibitManyArgs)
  my ($check_name, $qc_in, $qc_out, $l, $is_plex, $subset) = @_;

  my $args = {'id_run' => $l->id_run, 'position' => $l->position};
  if ($is_plex && defined $l->tag_index) {
    $args->{'tag_index'} = $l->tag_index;
  }
  if ($check_name eq 'bam_flagstats') {
    if ($subset) {
      $args->{'subset'} = $subset;
    }
    $args->{'qc_in'}  = $qc_in;
  } else {
    $args->{'qc_in'}  = q[$] . 'PWD';
  }
  $args->{'qc_out'} = $qc_out;
  $args->{'check'}  = $check_name;
  my $command = q[];
  foreach my $arg (sort keys %{$args}) {
    $command .= join q[ ], q[ --].$arg, $args->{$arg};
  }
  return $QC_SCRIPT_NAME . $command;
}

sub _generate_command_arguments {
  my ( $self, $positions ) = @_;

  my @positions = @{ $positions };
  if (!@positions) {
    return;
  }
  my $bam_filename = $self->id_run . q{_};
  my $ext = q{.bam};

  my $lane_lims_all = $self->lims->children_ia();
  foreach my $position ( @positions ) {
    my $lane_lims = $lane_lims_all->{$position};
    if (!$lane_lims) {
      $self->debyg(qq{No lims object for position $position});
      next;
    }
    if ( $self->is_indexed and $lane_lims->is_pool ) { # does the run have an indexing read _and_ does the LIMS have pool information : if so do plex level analyses
      my $plex_lims = $lane_lims->children_ia();
      $plex_lims->{0} ||= st::api::lims->new(driver=>$lane_lims->driver, id_run=>$lane_lims->id_run, position=>$lane_lims->position, tag_index=>0);
      foreach my $tag_index ( @{ $self->get_tag_index_list($position) } ) {
        my $l = $plex_lims->{$tag_index};
        if (!$l) {
          $self->debug(qq{No lims object for position $position tag index $tag_index});
          next;
        }
        my $ji = $self->_job_index($position, $tag_index);
        $self->_job_args->{$ji} = $self->_lsf_alignment_command($l,1);
        $self->_using_alt_reference($self->_is_alt_reference($l));
      }
    } else { # do lane level analyses
      my $l = $lane_lims;
      my $ji = $self->_job_index($position);
      $self->_job_args->{$ji} = $self->_lsf_alignment_command($l);
    }
  }
  return;
}

sub _has_newer_flowcell { # is HiSeq High Throughput >= V4, Rapid Run >= V2
  my ($self) = @_;
  return $self->flowcell_id() =~ /(?:A[N-Z]|[B-Z][[:upper:]])XX\z/smx;
}

sub _do_rna_analysis {
  my ($self, $l) = @_;
  my $lstring = $l->to_string;
  if (!$l->library_type || $l->library_type !~ /(?:(?:cD|R)NA|DAFT)/sxm) {
    $self->debug(qq{$lstring - not RNA library type});
    return 0;
  }
  if((not $l->reference_genome) or (not $l->reference_genome =~ /Homo_sapiens|Mus_musculus|Plasmodium_(?:falciparum|berghei)/smx)){
    $self->debug(qq{$lstring - Not human or mouse or plasmodium falciparum or berghei (so skipping RNAseq analysis for now)}); #TODO: RNAseq should work on all eukaryotes?
    return 0;
  }
  if(not $self->_transcriptome($l)->transcriptome_index_name()){
    $self->debug(qq{$lstring - no transcriptome set}); #TODO: RNAseq should work without transcriptome?
    return 0;
  }
  if(not $self->is_paired_read){
    $self->debug(qq{$lstring - Single end run (so skipping RNAseq analysis for now)}); #TODO: RNAseq should work on single end data
    return 0;
  }
  $self->debug(qq{$lstring - Do RNAseq analysis....});

  return 1;
}

sub _transcriptome {
    my ($self, $l) = @_;
    my $t = npg_tracking::data::transcriptome->new (
                {'id_run'     => $l->id_run, #TODO: use lims object?
                 'position'   => $l->position,
                 'tag_index'  => $l->tag_index,
                 ( $self->repository ? ('repository' => $self->repository):())
                });
    return($t);
}

sub _do_bait_stats_analysis {
  my ($self, $l) = @_;
  my $lstring = $l->to_string;
  if(not $self->_ref($l,q(fasta)) or not $l->alignments_in_bam) {
      $self->debug(qq{$lstring - no reference or no alignments set});
      return 0;
  }
  if(not $self->_bait($l)->bait_name){
      $self->debug(qq{$lstring - No bait set});
      return 0;
  }
  if(not $self->_bait($l)->bait_path){
      $self->debug(qq{$lstring - No bait path found});
      return 0;
  }
  $self->debug(qq{$lstring - Doing optional bait stats analysis....});

  return 1;
}

sub _bait{
  my($self,$l) = @_;
  return npg_tracking::data::bait->new (
                {'id_run'     => $l->id_run,
                 'position'   => $l->position,
                 'tag_index'  => $l->tag_index,
                 ( $self->repository ? ('repository' => $self->repository):())
                });
}

sub _ref {
  my ($self, $l, $aligner) = @_;
  my $lstring = $l->to_string;

  my $href = { 'aligner' => ($aligner||'bowtie2'), 'lims' => $l, };
  if ($self->repository) {
    $href->{'repository'} = $self->repository;
  }
  my $ruser = Moose::Meta::Class->create_anon_class(
       roles => [qw/npg_tracking::data::reference::find/])->new_object($href);
  my @refs;
  try {
    @refs =  @{$ruser->refs};
  } catch {
    $self->error("Error getting reference: $_");
  };

  if (!@refs) {
    $self->warn(qq{No reference genome set for $lstring});
    return 0;
  }
  if (scalar @refs > 1) {
    $self->error(qq{Multiple references for $lstring});
    return 0;
  }
  $self->info(qq{Reference set for $lstring: $refs[0]});

  return $refs[0];
}

sub _job_index {
  my ($self, $position, $tag_index) = @_;
  if (!$position) {
    $self->logcroak('Position undefined or zero');
  }
  if (defined $tag_index) {
    return sprintf q{%i%04i}, $position, $tag_index;
  }
  return $position;
}

sub _default_resources {
  my ( $self ) = @_;
  my $hosts = 1;
  my $num_slots = $self->general_values_conf()->{'seq_alignment_slots'} || $NUM_SLOTS;
  return (join q[ ], npg_pipeline::lsf_job->new(memory => $MEMORY)->memory_spec(), "-R 'span[hosts=$hosts]'", "-n$num_slots");
}

sub _default_human_split_ref {
   my ($self, $aligner, $repos) = @_;

   my $ruser = Moose::Meta::Class->create_anon_class(
          roles => [qw/npg_tracking::data::reference::find/])
          ->new_object({
                         species => q{Homo_sapiens},
                         aligner => $aligner,
                        ($repos ? (q(repository)=>$repos) : ())
                       } );

   my $human_ref;
   eval {
      $human_ref = $ruser->refs->[0];
      if($aligner eq q{picard}) {
        $human_ref .= q{.dict};
      }
      1;
   } or do{
      carp $EVAL_ERROR;
   };

   return $human_ref;
}

sub _is_alt_reference {
    my ($self, $l) = @_;
    return -e $self->_ref($l,'bwa0_6') . '.alt';
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
__END__

=head1 NAME

npg_pipeline::archive::file::generation::seq_alignment

=head1 SYNOPSIS

  my $oAfgfq = npg_pipeline::archive::file::generation::seq_alignment->new(
    run_folder => $sRunFolder,
  );

=head1 DESCRIPTION

LSF job creation for seq alignment

=head1 SUBROUTINES/METHODS

=head2 generate - generates and submits lsf job

=head1 DIAGNOSTICS

=head1 CONFIGURATION AND ENVIRONMENT

=head1 DEPENDENCIES

=over

=item Carp

=item English -no_match_vars

=item Readonly

=item Moose

=item Moose::Meta::Class

=item Try::Tiny

=item File::Slurp

=item npg_tracking::data::reference::find

=item npg_tracking::data::bait

=back

=head1 INCOMPATIBILITIES

=head1 BUGS AND LIMITATIONS

=head1 AUTHOR

David K. Jackson (david.jackson@sanger.ac.uk)

=head1 LICENSE AND COPYRIGHT

Copyright (C) 2016 Genome Research Ltd

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.
