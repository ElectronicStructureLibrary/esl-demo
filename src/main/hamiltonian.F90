module esl_hamiltonian_m
  use prec, only : dp,ip
  use esl_basis_m
  use esl_geometry_m
  use esl_grid_m
  use esl_hamiltonian_pw_m
  use esl_hamiltonian_ac_m
  use esl_sparse_pattern_m
  use esl_potential_m
  use esl_states_m

#ifdef WITH_MPI
  use mpi
#endif


  implicit none
  private

  public :: hamiltonian_t

  !Data structure for the Hamiltonian
  type hamiltonian_t
    type(potential_t)       :: potential
    type(hamiltonian_pw_t)  :: pw
    type(hamiltonian_ac_t)  :: ac
  contains
    private
    procedure, public :: init
    procedure, public :: eigensolver
  end type hamiltonian_t

contains

  !< Initialize the Hamiltonian
  !<
  !< For AC the following happens:
  !<  1. Initialize AC object by associating sparse patterns
  !<     with the internal Hamiltonian elements
  !<  2. Calculate the non-SCF terms for the Hamiltonian.
  !<     They are the V_KB projectors and the kinetic part of
  !<     the Hamiltonian.
  subroutine init(this, basis, geo, states, periodic)
    class(hamiltonian_t) :: this
    type(basis_t),    intent(in) :: basis
    type(geometry_t), intent(in) :: geo
    type(states_t),   intent(in) :: states
    logical,          intent(in) :: periodic
 
    integer mpicomm

    mpicomm = 0
#ifdef WITH_MPI
    mpicomm = MPI_COMM_WORLD
#endif

    select case (basis%type)
    case ( PLANEWAVES )
      call this%potential%init(basis%pw, states, geo, periodic)
      call this%pw%init(this%potential, mpicomm)
    case ( ATOMCENTERED )
      call this%potential%init(basis%ac, states, geo, periodic)
      
      ! Initialize the AC part of the Hamiltonian
      call this%ac%init(basis%ac%sparse_pattern, states%nspin)
      
      ! Immediately calculate the non-SCF dependent Hamiltonian quantities
      ! This *should* only be done once per geometry
      ! and thus we might as well do it here
      call this%ac%calculate_H0(basis%ac, geo)

    end select
 
  end subroutine init

  !Eigensolver
  !----------------------------------------------------
  subroutine eigensolver(this, basis, states)
    class(hamiltonian_t), intent(inout) :: this
    type(basis_t),  intent(in)    :: basis
    type(states_t), intent(inout) :: states

    select case (basis%type)
    case ( PLANEWAVES )
      call this%pw%eigensolver(basis%pw, states)
    case ( ATOMCENTERED )
      call this%ac%eigensolver(basis%ac, states)
    end select

  end subroutine eigensolver
  
end module esl_hamiltonian_m
