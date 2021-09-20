! Copyright (C) 2001 PWSCF group
! This file is distributed under the terms of the
! GNU General Public License. See the file `License'
! in the root directory of the present distribution,
! or http://www.gnu.org/copyleft/gpl.txt .
!
!#include "f_defs.h"
!#define DEBUG
#define ZERO ( 0.D0, 0.D0 )
#define ONE  ( 1.D0, 0.D0 )
!
!-----------------------------------------------------------------------
subroutine apply_u_matrix(evc_ks, evc_var, occ_mat, ik_eff, n_orb)
  !-----------------------------------------------------------------------
  !
  !! This routine rotate the KS orbitals generated by PWSCF according to 
  !! the unitary matrices U. The unitary matrices are generated
  !! by wannier90 and read in read_wannier.f90
  !
  USE io_global,            ONLY : stdout
  USE kinds,                ONLY : DP
  USE control_kc_wann,      ONLY : unimatrx, unimatrx_opt, &
                                   num_wann, has_disentangle, kc_iverbosity
  USE wvfct,                ONLY : npwx, nbnd
  USE noncollin_module,     ONLY : npol
  USE mp,                   ONLY : mp_bcast, mp_sum
  !USE mp_bands,             ONLY : intra_bgrp_comm
  !
  USE wvfct,                 ONLY : wg
  USE klist,                 ONLY : wk, xk
  !
  !
  ! Local Variable
  !
  IMPLICIT NONE
  !
  COMPLEX (DP), INTENT (IN):: evc_KS(npwx*npol, nbnd)
  ! ... the KS wfcs
  INTEGER, INTENT (IN) ::  ik_eff
  ! ... the global kpoint index (needed to use the correct Uij(k)
  COMPLEX(DP), INTENT(INOUT):: evc_var(npwx*npol, nbnd)
  ! ... The rotate wfc 
  INTEGER, INTENT(INOUT) :: n_orb
  ! ... the manifold space
  REAL(DP), INTENT(INOUT) :: occ_mat (num_wann,num_wann)
  INTEGER i, j, dim_ks, v
  !
  COMPLEX(DP), ALLOCATABLE :: evc_opt(:,:) 
  ! ... The optimal set of rotate wfc after disentanglement
  INTEGER :: iwann!, jwann
  !COMPLEX (DP) :: u_vi, udag_vj
  REAL(DP) :: trace
  COMPLEX(DP) :: eigvc(num_wann,num_wann)
  REAL(DP) :: eigvl(num_wann)
  !
  COMPLEX(DP), ALLOCATABLE :: aux(:,:), aux1(:,:), Umat(:,:), Umat_opt(:,:), fuv(:,:), c_occ_mat(:,:)
  !
  ! ... Rotate the KS orbitals ... 
  ! ... |phi_i> = \sum_j |psi_j>*U_ji
  !
  ALLOCATE ( evc_opt(npwx*npol,num_wann) )
  evc_opt(:,:) = CMPLX(0.D0,0.D0,kind=DP)
  !
  dim_ks = nbnd 
  IF ( .NOT. has_disentangle) dim_ks = num_wann
  !
  DO i = 1, num_wann
    !
    DO j = 1, dim_ks
      !
      !evc_opt(:,i) = evc_opt(:,i) + evc_ks(:,j) * unimatrx_opt (i,j,ik_eff)
      evc_opt(:,i) = evc_opt(:,i) + evc_ks(:,j) * unimatrx_opt (j,i,ik_eff)
      !
    ENDDO
    !
    !WRITE(*,'("evc_ks", 6f15.10)') evc_ks(1:3,i+nbnd_occ(ik))
    !WRITE(*,'("ec_opt", 6f15.10)') evc_opt(1:3,i)
    !
  ENDDO
  !
  ! ... Rotate the KS orbitals ... 
  ! ... |phi_i> = \sum_j |psi_j>*U_ji
  !
  DO i = 1, num_wann
     !
     evc_var(:,i) = ZERO
     !
     DO j = 1, num_wann
        !
        evc_var(:,i) = evc_var(:,i) + evc_opt(:,j) * unimatrx (j,i,ik_eff) 
        !
     ENDDO
     !
  ENDDO
  !
  ! FIXME: useless
  n_orb = num_wann
  !
  ! Compute the occupation matrix
  !
  ! NEW
  trace = 0.D0
  occ_mat = 0.D0
  ALLOCATE (aux (dim_ks, num_wann), aux1 (dim_ks, num_wann), c_occ_mat(num_wann,num_wann) )
  ALLOCATE ( Umat(num_wann, num_wann), Umat_opt(dim_ks, num_wann), fuv(dim_ks, dim_ks) )
  aux  = ZERO
  aux1  = ZERO
  c_occ_mat = ZERO
  fuv = ZERO
  Umat = ZERO
  Umat_opt = ZERO
  Umat(:,:) = unimatrx (:,:,ik_eff)
  Umat_opt(:,:) = unimatrx_opt (:,:,ik_eff)
  !
  ! MAtrix product Utot = Uopt x U
  CALL ZGEMM( 'N', 'N', dim_ks, num_wann, num_wann, ONE, &
                    Umat_opt, dim_ks, Umat, num_wann, ZERO, aux, dim_ks )
  !
  ! The canonical occupation matrix (fermi dirac or alike)
  fuv = ZERO
  DO v = 1, dim_ks; fuv(v,v)=CMPLX(wg(v,ik_eff)/wk(ik_eff), 0.D0, kind = DP); ENDDO
  !
  !  f_ab = sum_vv' Utot^dag_bv f_vv' Utot_v'a
  !  1) aux1_va = sum_v' f_vv' Utot_v'a
  CALL ZGEMM( 'N', 'N', dim_ks, num_wann, dim_ks, ONE, &
                    fuv, dim_ks, aux, dim_ks, ZERO, aux1, dim_ks )
  !
  ! 2) sum_v Utot^dag_bv aux1_va
  CALL ZGEMM( 'C', 'N', num_wann, num_wann, dim_ks, ONE, &
                    aux, dim_ks, aux1, dim_ks, ZERO, c_occ_mat, num_wann )
  !
  occ_mat = REAL(c_occ_mat)
  DO iwann=1, num_wann; trace =trace + occ_mat(iwann,iwann); ENDDO
  !
  IF (kc_iverbosity > 1) THEN 
    WRITE(stdout,'(/,8X,"Rotated Occupation Matrix (ROM) ik=", i5, 3x, "xk =", 3F8.4,/)') ik_eff, xk(:,ik_eff)
    DO i = 1, num_wann;  WRITE(stdout,'(8x, 20f8.4)') (occ_mat(i,j), j=1,num_wann); ENDDO
    WRITE(stdout,'(/,8X, "Trace", F20.15)') trace
    !
    CALL rdiagh( num_wann, occ_mat, num_wann, eigvl, eigvc )
    WRITE( stdout, '(8x,"ROM eig  ",8F9.4)' ) (eigvl(iwann), iwann=1,num_wann)

  ENDIF
  !
  DEALLOCATE (aux, aux1, Umat, Umat_opt, fuv, c_occ_mat)
  !
!  ! OLD 
!  trace = 0.D0
!  occ_mat = 0.D0
!  DO iwann = 1, num_wann
!   DO jwann = 1, num_wann
!    DO v=1,dim_ks
!      u_vi = SUM ( CONJG(evc_ks(:,v))*evc_var(:,iwann) )
!      udag_vj = SUM ( CONJG(evc_var(:,jwann))*evc_ks(:,v) )
!      CALL mp_sum (u_vi, intra_bgrp_comm)
!      CALL mp_sum (udag_vj, intra_bgrp_comm)
!      occ_mat(iwann,jwann) = occ_mat(iwann,jwann) + REAL(u_vi*udag_vj* wg(v,ik_eff)/wk(ik_eff))
!      !
!!      occ_mat(iwann,jwann) = occ_mat(iwann,jwann) + &
!!                             SUM ( CONJG(evc_ks(:,v))*evc_var(:,iwann) ) * &
!!                             SUM ( CONJG(evc_var(:,jwann))*evc_ks(:,v) ) * wg(v,ik_eff)/wk(ik_eff)
!    ENDDO
!   ENDDO
!   trace = trace + occ_mat(iwann,iwann)
!  ENDDO
!  !
!  IF (kc_iverbosity > 1) THEN 
!    WRITE(stdout,'(/,8X,"Rotated Occupation Matrix (ROM) ik=", i5, 3x, "xk =", 3F8.4,/)') ik_eff, xk(:,ik_eff)
!    DO i = 1, num_wann;  WRITE(stdout,'(8x, 20f8.4)') (occ_mat(i,j), j=1,num_wann); ENDDO
!    WRITE(stdout,'(/,8X, "Trace", F20.15)') trace
!    !
!    CALL rdiagh( num_wann, occ_mat, num_wann, eigvl, eigvc )
!    WRITE( stdout, '(8x,"ROM eig  ",8F9.4)' ) (eigvl(iwann), iwann=1,num_wann)
!
!  ENDIF
  !
  !
  DEALLOCATE ( evc_opt )
  !
END subroutine apply_u_matrix
