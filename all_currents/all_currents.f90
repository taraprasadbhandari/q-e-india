subroutine read_all_currents_namelists(iunit)
     use zero_mod
     use hartree_mod
     use io_global, ONLY: stdout, ionode, ionode_id
     implicit none
     integer, intent(in) :: iunit
     integer :: ios
     CHARACTER(LEN=256), EXTERNAL :: trimcheck
     
     NAMELIST /energy_current/ delta_t, init_linear, &
        file_output, trajdir, vel_input_units ,&
        eta, n_max, status, l_zero

     !
     !   set default values for variables in namelist
     !
     !prefix_due = 'pwscf' !TODO: remove
     delta_t = 1.d0
     n_max = 5 ! number of periodic cells in each direction used to sum stuff in zero current
     eta = 1.0 ! ewald sum convergence parameter
     status = "undefined"
     init_linear = "scratch" ! 'scratch' or 'restart'. If 'scratch', saves a restart file in project routine. If 'restart', it starts from the saved restart file, and then save again it.
     file_output = "corrente_def"
     !file_dativel = "velocita_def"
     READ (iunit, energy_current, IOSTAT=ios)
     IF (ios /= 0) CALL errore('main', 'reading energy_current namelist', ABS(ios))    

end subroutine

subroutine bcast_all_current_namelist()
     use zero_mod
     use hartree_mod
     use io_global, ONLY: stdout, ionode, ionode_id
     !use mp_global, ONLY: kunit, mp_startup
     use mp_world, ONLY: mpime, world_comm
     use mp, ONLY: mp_bcast !, mp_barrier
     implicit none
     CALL mp_bcast(trajdir, ionode_id, world_comm)
!     CALL mp_bcast(prefix_uno, ionode_id, world_comm)
!     CALL mp_bcast(prefix_due, ionode_id, world_comm)
     CALL mp_bcast(delta_t, ionode_id, world_comm)
     CALL mp_bcast(eta, ionode_id, world_comm)
     CALL mp_bcast(n_max, ionode_id, world_comm)
     CALL mp_bcast(status, ionode_id, world_comm)
     CALL mp_bcast(init_linear, ionode_id, world_comm)
     CALL mp_bcast(file_output, ionode_id, world_comm)
     !CALL mp_bcast(file_dativel, ionode_id, world_comm)

end subroutine

subroutine check_input()
     use input_parameters, only : rd_pos, tapos, rd_vel, tavel, atomic_positions, ion_velocities
use  ions_base,     ONLY :  tau, tau_format, nat
     use zero_mod, only : vel_input_units, ion_vel
     use hartree_mod, only : delta_t
     implicit none
     if (.not. tavel) &
        call errore('read_vel', 'error: must provide velocities in input',1)
     if (ion_velocities /= 'from_input') &
        call errore('read_vel', 'error: atomic_velocities must be "from_input"',1)
     if (.not. allocated(ion_vel)) &
        allocate(ion_vel, source=rd_vel)

end subroutine


subroutine run_pwscf(exit_status)
USE control_flags,        ONLY : conv_elec, gamma_only, ethr, lscf, treinit_gvecs
 USE check_stop,           ONLY : check_stop_init, check_stop_now
USE qexsd_module,         ONLY : qexsd_set_status
implicit none
INTEGER, INTENT(OUT) :: exit_status
exit_status=0
     IF ( .NOT. lscf) THEN
        CALL non_scf()
     ELSE
        CALL electrons()
     END IF
     !
     ! ... code stopped by user or not converged
     !
     IF ( check_stop_now() .OR. .NOT. conv_elec ) THEN
        IF ( check_stop_now() ) exit_status = 255
        IF ( .NOT. conv_elec )  exit_status =  2
        CALL qexsd_set_status(exit_status)
        CALL punch( 'config' )
        RETURN
     ENDIF
end subroutine

subroutine prepare_next_step()
USE extrapolation,        ONLY : update_pot
USE control_flags,        ONLY : ethr
use  ions_base,     ONLY :  tau, tau_format, nat
use cell_base, only : alat
use dynamics_module, only : vel
use io_global, ONLY: ionode, ionode_id
USE mp_world,             ONLY : world_comm
use mp, ONLY: mp_bcast, mp_barrier
use hartree_mod, only : evc_due,delta_t
use zero_mod, only : vel_input_units, ion_vel
use wavefunctions, only : evc 
     !save old evc

     if (allocated(evc_due)) then
         evc_due=evc
     else
         allocate(evc_due, source=evc)
     end if
     !set new positions
     if (ionode) then
         if (vel_input_units=='CP') then ! atomic units of cp are different
            vel= 2.d0 * vel
         else if (vel_input_units=='PW') then
            !do nothing
         else
            call errore('read_vel', 'error: unknown vel_input_units',1 )
         endif
     endif
     !broadcast
     CALL mp_bcast(tau, ionode_id, world_comm)
     CALL mp_bcast(vel, ionode_id, world_comm)
     if (.not. allocated(ion_vel)) then
         allocate(ion_vel,source=vel)
     else
         ion_vel=vel
     endif
     vel=vel/alat
     tau=tau + delta_t * vel
     call mp_barrier(world_comm) 
     call update_pot()
     call hinit1()
     ethr = 1.0D-6
end subroutine

program all_currents
     use hartree_mod, only : evc_uno,evc_due
     USE environment, ONLY: environment_start, environment_end
     use io_global, ONLY: ionode ! stdout, ionode, ionode_id
     use wavefunctions, only : evc

!from ../PW/src/pwscf.f90
  USE mp_global,            ONLY : mp_startup
  USE mp_world,             ONLY : world_comm
     use mp, ONLY: mp_bcast, mp_barrier
  USE mp_pools,             ONLY : intra_pool_comm
  USE mp_bands,             ONLY : intra_bgrp_comm, inter_bgrp_comm
  !USE mp_exx,               ONLY : negrp
  USE read_input,           ONLY : read_input_file
  USE command_line_options, ONLY : input_file_, command_line, ndiag_, nimage_
  USE check_stop,           ONLY : check_stop_init
!from ../Modules/read_input.f90
     USE read_namelists_module, ONLY : read_namelists
     USE read_cards_module,     ONLY : read_cards

     implicit none
     integer :: exit_status
!from ../PW/src/pwscf.f90
     include 'laxlib.fh'


!from ../PW/src/pwscf.f90
     CALL mp_startup()
     CALL laxlib_start ( ndiag_, world_comm, intra_bgrp_comm, &
                         do_distr_diag_inside_bgrp_ = .TRUE. )
     CALL set_mpi_comm_4_solvers( intra_pool_comm, intra_bgrp_comm, &
                               inter_bgrp_comm )


     CALL environment_start('PWSCF')

     IF (ionode) THEN
        !
        CALL input_from_file()
        !
        ! all_currents input
        call read_all_currents_namelists( 5 )
     endif
        !
        ! PW input
        call read_namelists( 'PW', 5 )
        call read_cards( 'PW', 5 )

     ! create second set of atomic positions
     call check_input()
 
     call mp_barrier(intra_pool_comm)
     call bcast_all_current_namelist() 
     call iosys()    ! ../PW/src/input.f90    save in internal variables
     call check_stop_init() ! ../PW/src/input.f90
     call setup()    ! ../PW/src/setup.f90    setup the calculation
     call init_run() ! ../PW/src/init_run.f90 allocate stuff
 

     ! in principle now scf is ready to start 
     
     call run_pwscf(exit_status)
     if (exit_status /= 0 ) goto 100

     call prepare_next_step() ! this stores value of evc and setup tau and ion_vel

     call run_pwscf(exit_status)
     if (exit_status /= 0 ) goto 100
     if (allocated(evc_uno)) then
         evc_uno=evc
     else
         allocate(evc_uno, source=evc)
     end if

     call allocate_zero()
     call init_zero() ! only once per all trajectory
     call setup_nbnd_occ()

     call routine_hartree()

     !init of all_current part
!
     call routine_zero()
     deallocate (evc_uno)
     deallocate (evc_due)

     ! shutdown stuff
100     call laxlib_end()
     call stop_run( exit_status )
     call do_stop( exit_status )
     stop
end program all_currents
