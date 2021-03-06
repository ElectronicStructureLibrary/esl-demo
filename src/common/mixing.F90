module esl_mixing_m
  use prec, only : dp,ip

  implicit none
  private

  public :: mixing_t

  ! Data structure for the mixer
  type mixing_t

    real(dp) :: alpha !< Mixing parameter

  contains
    private
    procedure, public :: init
    procedure, public :: linear
  end type mixing_t

contains

  !Initialize the mixer
  !----------------------------------------------------
  subroutine init(this)
    use fdf, only: fdf_get
    class(mixing_t) :: this

    ! For the moment we read this from SCF.Mix.alpha
    this%alpha = fdf_get('SCF.Mix.alpha', 0.1_dp)

  end subroutine init

  ! Mix two input vectors
  subroutine linear(this, np, in, out, next)
    class(mixing_t), intent(in) :: this
    integer, intent(in) :: np
    real(dp), intent(in) :: in(:)
    real(dp), intent(in) :: out(:)
    real(dp), intent(inout) :: next(:)

    real(dp) :: beta
    integer :: ip

    beta = 1._dp - this%alpha
    do ip = 1, np
      next(ip) = in(ip) * beta + out(ip) * this%alpha
    end do

  end subroutine linear

end module esl_mixing_m
