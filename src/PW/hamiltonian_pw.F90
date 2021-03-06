module esl_hamiltonian_pw_m
  use prec, only:dp, ip
  use elsi_rci
  use elsi_rci_constants
  use elsi_rci_omm
  use elsi_rci_precision, only:r8, i4

  use esl_basis_pw_m
  use esl_grid_m
  use esl_potential_m
  use esl_states_m
  use esl_utils_pw_m

#ifdef WITH_MPI
  use mpi
#endif

  implicit none
  private

  public :: &
    hamiltonian_pw_t, &
    hamiltonian_pw_apply, &
    hamiltonian_pw_apply_local

  type work_matrix_t
    complex(kind=dp), allocatable :: mat(:, :)
  end type work_matrix_t

  !Data structure for the Hamiltonian
  type hamiltonian_pw_t
    type(potential_t), pointer :: pot
  contains
    private
    procedure, public :: init
    procedure, public :: eigensolver
    final :: finalizer
  end type hamiltonian_pw_t

contains

  !Initialize the Hamiltonian
  !----------------------------------------------------
  subroutine init(this, pot, comm)
    class(hamiltonian_pw_t) :: this
    type(potential_t), target, intent(in) :: pot
    integer, intent(in) :: comm

    this%pot => pot

    !call this%dist%init_(comm, 1)

    !call elsi_init(this%e_h, solver, 1, 0, matrix_size, real(states%nel,kind=dp), states%nstates)

  end subroutine init

  !Release
  !----------------------------------------------------
  subroutine finalizer(this)
    type(hamiltonian_pw_t) :: this

!    call this%dist%delete_()

    nullify (this%pot)

  end subroutine finalizer

  !Eigensolver
  !----------------------------------------------------
  subroutine eigensolver(this, pw, states)
    class(hamiltonian_pw_t) :: this
    type(basis_pw_t), intent(in)  :: pw
    type(states_t), intent(inout) :: states

    integer :: ii, jj, lda, ldb, ldc
    real(kind=r8), allocatable :: result_in(:)
    type(rci_instr)      :: iS
    integer(kind=i4) :: task, m, n, ijob
    real(kind=r8) :: e_min = 0.0_r8
    real(kind=r8) :: cg_tol = 0.00001_r8
    integer(kind=i4) :: max_iter = 100
    logical :: long_out = .true.
    type(work_matrix_t), allocatable :: work(:)

    complex(kind=dp), allocatable :: Worktmp(:)
    real(kind=r8), allocatable :: RWorktmp(:)
    integer(kind=i4) :: lWorktmp
    integer(kind=i4) :: info

    m = pw%size
    n = states%nstates

    !OMM needs 28 matrices
    allocate (work(1:28))
    do ii = 1, 11
      allocate (work(ii)%mat(1:m, 1:n))
      work(ii)%mat(1:m, 1:n) = cmplx(0.d0, 0.d0, r8)
    end do
    do ii = 21, 28
      allocate (work(ii)%mat(1:n, 1:n))
      work(ii)%mat(1:n, 1:n) = cmplx(0.d0, 0.d0, r8)
    end do

    !We copy the states in work(1)
    !TODO support spin and kpoint
    do ii = 1, n
      work(1)%mat(1:pw%size, ii) = states%states(ii, 1, 1)%zcoef(1:pw%size)
    end do

    !result_in is also used for computing the eigenvalues
    allocate (result_in(n))
    ijob = -1
    do
      call rci_omm(ijob, iS, task, result_in, m, n, &
                   e_min, cg_tol, max_iter, long_out)

      select case (task)
      case (ELSI_RCI_NULL)
      case (ELSI_RCI_CONVERGE)
        exit
      case (ELSI_RCI_STOP)
        print *, "ELSI RCI did not converged."
        exit
      case (ELSI_RCI_H_MULTI) ! B = H^(trH) * A
        do ii = 1, iS%n
          call hamiltonian_pw_apply(this%pot, pw, work(iS%Aidx)%mat(1:iS%m, ii), work(iS%Bidx)%mat(1:iS%m, ii))
        end do

      case (ELSI_RCI_S_MULTI) ! B = S^(trS) * A
        !No overlap matrix
        work(iS%Bidx)%mat = work(iS%Aidx)%mat

      case (ELSI_RCI_P_MULTI) ! B = P^(trP) * A
!work(iS%Bidx)%mat = work(iS%Aidx)%mat


        !No overlap matrix
        do ii = 1, iS%n
          call hamiltonian_preconditioner(pw, work(iS%Aidx)%mat(1:iS%m, ii), work(iS%Bidx)%mat(1:iS%m, ii))
        end do

      case (ELSI_RCI_GEMM) ! C = alpha * A^(trA) * B^(trB) + beta * C
        lda = size(work(iS%Aidx)%mat, 1)
        ldb = size(work(iS%Bidx)%mat, 1)
        ldc = size(work(iS%Cidx)%mat, 1)
        call zgemm(iS%TrA, iS%TrB, iS%m, iS%n, iS%k, &
                   cmplx(iS%alpha, 0.0_r8, r8), &
                   work(iS%Aidx)%mat, lda, work(iS%Bidx)%mat, ldb, &
                   cmplx(iS%beta, 0.0_r8, r8), work(iS%Cidx)%mat, ldc)

      case (ELSI_RCI_AXPY) ! B = alpha * A + B
        call zaxpy(iS%m*iS%n, cmplx(iS%alpha, 0.0_r8, r8), &
                   work(iS%Aidx)%mat, 1, &
                   work(iS%Bidx)%mat, 1)

      case (ELSI_RCI_COPY) ! B = A^(trA)
        if (iS%TrA == 'N') then
          work(iS%Bidx)%mat = work(iS%Aidx)%mat
        end if
        if (iS%TrA == 'T') then
          work(iS%Bidx)%mat = transpose(work(iS%Aidx)%mat)
        end if
        if (iS%TrA == 'C') then
          work(iS%Bidx)%mat = conjg(transpose(work(iS%Aidx)%mat))
        end if

      case (ELSI_RCI_TRACE) ! res = trace(A)
        result_in(1) = 0.0_DP
        do ii = 1, iS%m
          result_in(1) = result_in(1) &
                         + real(work(iS%Aidx)%mat(ii, ii), kind=dp)
        end do
      case (ELSI_RCI_DOT) ! res = trace(A * B)
        result_in(1) = 0.d0
        do ii = 1, iS%m
          do jj = 1, iS%n
            result_in(1) = result_in(1) &
                           + real(conjg(work(iS%Aidx)%mat(ii, jj)) &
                                  *work(iS%Bidx)%mat(ii, jj), kind=dp)
          end do
        end do

      case (ELSI_RCI_SCALE) ! A = alpha * A
        work(iS%Aidx)%mat = cmplx(iS%alpha, 0.0_r8, r8)*work(iS%Aidx)%mat

      case default
        print *, 'Unsupported RCI operation ', task
      end select

    end do

    !We copy the states back from work(1)
    !Work(2) contains H|\psi>
    !TODO support spin and kpoint
    lWorktmp = max(1, 2*n - 1)
    allocate (Worktmp(lWorktmp))
    allocate (RWorktmp(max(1, 3*n - 2)))
    lda = size(Work(21)%Mat, 1)
    call zheev('V', 'L', n, &
               Work(21)%Mat, lda, result_in, &
               Worktmp, lWorktmp, RWorktmp, info)
    deallocate (Worktmp)
    deallocate (RWorktmp)
    lda = size(work(1)%mat, 1)
    ldb = size(work(21)%mat, 1)
    ldc = size(work(11)%mat, 1)
    call zgemm('N', 'N', m, n, n, cmplx(1.0_r8,0.0_r8,r8), &
               work(1)%mat, lda, work(21)%mat, ldb, &
               cmplx(0.0_r8,0.0_r8,r8), work(11)%mat, ldc)

    do ii = 1, n
      states%states(ii, 1, 1)%zcoef(1:pw%size) = work(11)%mat(1:pw%size, ii)
      states%eigenvalues(ii, 1, 1) = result_in(ii)
    end do

    deallocate (result_in)
    do ii = 1, 11
      deallocate (work(ii)%mat)
    end do
    do ii = 21, 28
      deallocate (work(ii)%mat)
    end do
    deallocate (work)

  end subroutine eigensolver

  !Apply the Hamiltonian matrix
  !----------------------------------------------------
  subroutine hamiltonian_pw_apply(pot, pw, psi, hpsi)
    type(potential_t), intent(in)    :: pot
    type(basis_pw_t), intent(in)    :: pw
    complex(dp), intent(in)      :: psi(:)
    complex(dp), intent(inout)   :: hpsi(:)

    integer :: ic

    !We apply the Laplacian
    do ic = 1, pw%size
      hpsi(ic) = -0.5d0*psi(ic)*pw%gmod2(ic)
    end do

    call hamiltonian_pw_apply_local(pw, pot, psi, hpsi)

  end subroutine hamiltonian_pw_apply

  !Preconditioning
  !----------------------------------------------------
  subroutine hamiltonian_preconditioner(pw, psi, hpsi)
    type(basis_pw_t), intent(in)    :: pw
    complex(dp), intent(in)      :: psi(:)
    complex(dp), intent(inout)   :: hpsi(:)

    integer :: ic

    !We apply the Laplacian
    do ic = 1, pw%size
      hpsi(ic) = 2.0d0*psi(ic)/(pw%gmod2(ic)+1.0e-08)
    end do

  end subroutine hamiltonian_preconditioner


  !Apply the local part of the Hamitonian to a wavefunction
  !----------------------------------------------------
  subroutine hamiltonian_pw_apply_local(pw, pot, psi, hpsi)
    type(basis_pw_t), intent(in)    :: pw
    type(potential_t), intent(in)    :: pot
    complex(dp), intent(in)    :: psi(:)
    complex(dp), intent(inout) :: hpsi(:)

    integer :: ip
    complex(kind=dp), allocatable :: psi_rs(:), vpsi_rs(:)

    !TODO: Here there is no spin

    allocate (psi_rs(1:pw%grid%np))
    allocate (vpsi_rs(1:pw%grid%np))
    vpsi_rs(1:pw%grid%np) = 0.d0

    call pw2grid(pw%grid, pw%gmap, pw%ndims, pw%size, psi, psi_rs)
    !Note that hartree contains the external potential (from PSolver)
    do ip = 1, pot%np
      vpsi_rs(ip) = vpsi_rs(ip) + (pot%hartree(ip) + pot%vxc(ip))*psi_rs(ip)
    end do
    call grid2pw(pw%grid, pw%gmap, pw%ndims, pw%size, vpsi_rs, hpsi, .true.)


    deallocate (psi_rs)
    deallocate (vpsi_rs)

  end subroutine hamiltonian_pw_apply_local

end module esl_hamiltonian_pw_m
