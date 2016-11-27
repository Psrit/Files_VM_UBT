# Inside the package we can directly use module name,
# while we must use Sift.`modulename` outside
# FIXME: (what's wrong with test.py inside this package?)
from ImagePreprocessing cimport gaussian_blur, decimation, DTYPE_t, SIGMA
from ImagePreprocessing import DTYPE
import numpy as np
cimport numpy as np
cimport cython


cdef class gaussian_octave:
    """
    The Gaussian octave generated by blurring an image repeatly.

    data: DTYPE_t[:, :, ::1]
        (`nsca`+3) images (each image is called a 'scale') blurred from scales[0]
        with different Gaussian kernels.
    nsca: int
        Number of keypoints, which satisfies: number of images in the octave =
        `nsca`+3
    sigma: double
        ...

    """
    cdef:
        DTYPE_t[:, :, ::1] scales
        int nsca
        double sigma

    def __init__(self, DTYPE[:, :1] input, int nsca, double sigma=SIGMA):
        cdef:
            int nrows = input.shape[0]
            int ncols = input.shape[1]
            int s
        self.nsca = nsca
        self.sigma = sigma
        self.scales = np.zeros([nsca + 3, nrows, ncols], dtype=DTYPE)
        self.scales[0] = input
        for s in range(1, nsca + 3):
            self.scales[s] = gaussian_blur(self.scales[0], 2 ** (s / nsca) * sigma)


cdef class gaussian_pyramid:
    """ The Gaussian pyramid of an input image. """
    cdef gaussian_octave[:] octaves

    def __init__(self, DTYPE[:, :1] input, int noct, int nsca):
        """
        :param input: input image (with buffer interface)
        :param noct: number of octaves
        :param nsca: number of scales in each octave - 3

        """
        pass
