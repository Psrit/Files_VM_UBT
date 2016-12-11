# cython: profile=True

# Inside the package we can directly use module name,
# while we must use Sift.`modulename` outside
# # FIXME: (what's wrong with test.py inside this package?)
# from ImagePreprocessing cimport gaussian_blur, decimation, DTYPE_t
from ImagePreprocessing import DTYPE
from ImagePreprocessing cimport decimation
from FeatureDescription cimport *
from Defaults import SCALES, INTERP_STEPS, CONTR_THR, STAB_THR, INIT_SIGMA, \
    SIGMA, DSAMP_INTVL, OUT_PATH
cimport Math as mt
import numpy as np
cimport numpy as np
cimport cython


@cython.boundscheck(False)
@cython.wraparound(False)
cdef class GaussianOctave:
    # FIXME: SOMETHING WRONG HERE
    """
    The Gaussian octave generated by blurring an image repeatly.

    scales: DTYPE_t[:, :, ::1]
        (`nscas`+3) images (each image is called a 'scale') blurred from scales[0]
        with different Gaussian kernels.
    diff_scales: DTYPE_t[:, :, ::1]
        (`nscas`+2) images (each image is called a 'scale') by doing difference
        between two neighbored images in `scales`.
    nscas: int
        Number of keypoints, which satisfies: number of images in the octave =
        `nscas`+3
    sigma0: DTYPE_t
        `sigma0` is the basic Gaussian parameter which means the 'bottom' image
        in the 'BOTTOM' octave is blurred from the original image by convoluting
        with G_\{sigma0}(x,y).
        Therefore, the 'bottom' image of 'THIS' octave is blurred from the
        original image by convoluting with G_\{(2 ** (n_oct)) * sigma0}(x,y).

    """
    # moved to .pxd for debugging
    # cdef:
    #     DTYPE_t[:, :, ::1] scales
    #     readonly DTYPE_t[:, :, ::1] diff_scales
    #     int nscas, nrows, ncols, n_oct
    #     DTYPE_t sigma0

    def __init__(self, DTYPE_t[:, ::1] input, int o, int nscas, DTYPE_t sigma):
        cdef:
            int s, r, c
            double sigma_base
        self.nrows = input.shape[0]
        self.ncols = input.shape[1]
        self.nscas = nscas
        self.n_oct = o
        self.sigma0 = sigma
        self.diff_scales = np.zeros([nscas + 2, self.nrows, self.ncols],
                                    dtype=DTYPE)
        self.scales = np.zeros([nscas + 3, self.nrows, self.ncols],
                               dtype=DTYPE)

        # sigma_base = (2 ** o) * sigma
        # FIXME: THE SIGMA_BASE HERE WORKS, BUT IS IT THE RIGHT ONE?
        sigma_base = sigma
        self.scales[0] = input
        for s in range(1, nscas + 3):
            self.scales[s] = gaussian_blur(self.scales[s - 1],
                    (2 ** (2.0 * s / nscas) - 2 ** (2.0 * (s - 1) / nscas)) ** 0.5
                                          * sigma_base)
                    # According to VLFeat's SIFT code(???):
                    # (2 ** (2.0 * (s + 1) / nscas) - 2 ** (2.0 * s / nscas)) ** 0.5
                    #                        * sigma_base)
            for r in range(0, self.nrows):
                for c in range(0, self.ncols):
                    self.diff_scales[s - 1, r, c] = \
                        self.scales[s, r, c] - self.scales[s - 1, r, c]

        print("Octave initialized. ")

    cdef tuple _find_exact_extremum(self, int s, int r, int c,
                                    int niter=INTERP_STEPS):
        cdef:
            DTYPE_t[:, ::1] deriv = np.zeros([3, 1], dtype=DTYPE)
            DTYPE_t[:, ::1] hessian3 = np.zeros([3, 3], dtype=DTYPE)
            DTYPE_t ds = 0, dr = 0, dc = 0
            int i
            int new_s = s, new_r = r, new_c = c
            DTYPE_t v
            DTYPE_t value_of_exact_extremum

        i = 0
        while i < niter:
            v =  self.diff_scales[s, r, c]
            # calculate the derivative vector:
            # ds
            deriv[0, 0] = (self.diff_scales[s + 1, r, c] -
                       self.diff_scales[s - 1, r, c]) / 2.0
            # dr
            deriv[1, 0] = (self.diff_scales[s, r + 1, c] -
                       self.diff_scales[s, r - 1, c]) / 2.0
            # dc
            deriv[2, 0] = (self.diff_scales[s, r, c + 1] -
                       self.diff_scales[s, r, c - 1]) / 2.0

            # calculate the Hessian matrix (on s, r, c):
            # /ds^2
            hessian3[0, 0] = self.diff_scales[s + 1, r, c] + \
                self.diff_scales[s - 1, r, c] - 2 * v
            # /dsdr
            hessian3[0, 1] = (self.diff_scales[s + 1, r + 1, c] +
                self.diff_scales[s - 1, r - 1, c] - self.diff_scales[s + 1, r - 1, c]
                - self.diff_scales[s - 1, r + 1, c]) / 4.0
            hessian3[1, 0] = hessian3[0, 1]
            # /dsdc
            hessian3[0, 2] = (self.diff_scales[s + 1, r, c + 1] +
                self.diff_scales[s - 1, r, c - 1] - self.diff_scales[s + 1, r, c - 1]
                - self.diff_scales[s - 1, r, c + 1]) / 4.0
            hessian3[2, 0] = hessian3[0, 2]
            # /dr^2
            hessian3[1, 1] = self.diff_scales[s, r + 1, c] + \
                self.diff_scales[s, r - 1, c] - 2 * v
            # /drdc
            hessian3[1, 2] = (self.diff_scales[s, r + 1, c + 1] +
                self.diff_scales[s, r - 1, c - 1] - self.diff_scales[s, r - 1, c + 1]
                - self.diff_scales[s, r + 1, c - 1]) / 4.0
            hessian3[2, 1] = hessian3[1, 2]
            # /dc^2
            hessian3[2, 2] = self.diff_scales[s, r, c + 1] + \
                self.diff_scales[s, r, c - 1] - 2 * v

            if mt.det(hessian3) != 0:
                [[ds], [dr], [dc]] = -np.dot(mt.inv(hessian3), deriv)
            # if the Hessian is noninvertible, simply let the offset vector to be 0:
            else:
                ds = 0
                dr = 0
                dc = 0

            # if ds > 0.5 and s <= self.nscas - 1:
            #     new_s += 1
            # elif ds < -0.5 and s >= 2:
            #     new_s -= 1
            # elif abs(ds) <= 0.5:
            #     pass
            # else:
            #     return None
            #
            # if dr > 0.5 and r <= self.nrows - 3:
            #     new_r += 1
            # elif dr < -0.5 and r >= 2:
            #     new_r -= 1
            # elif abs(dr) <= 0.5:
            #     pass
            # else:
            #     return None
            #
            # if dc > 0.5 and c <= self.ncols - 3:
            #     new_c += 1
            # elif dc < -0.5 and c >= 2:
            #     new_c -= 1
            # elif abs(dc) <= 0.5:
            #     pass
            # else:
            #     return None

            # if (s, r, c) are unchanged:
            if abs(ds) < 0.5 and abs(dr) < 0.5 and abs(dc) < 0.5:
                value_of_exact_extremum = v + \
                    0.5 * (deriv[0, 0] * ds + deriv[1, 0] * dr + deriv[2, 0] * dc)
                break

            # otherwise:
            new_s += round(ds)
            new_r += round(dr)
            new_c += round(dc)

            # new_s += 1 if ds > 0 else -1
            # new_r += 1 if dr > 0 else -1
            # new_c += 1 if dc > 0 else -1

            if new_s < 1 or new_s > self.nscas or \
               new_r < 1 or new_r > self.nrows - 2 or \
               new_c < 1 or new_c > self.ncols - 2:
                return None
                # print("(ds, dr, dc): ", (ds, dr, dc))
                # print("(s, r, c): ", (s, r, c))
                # value_of_exact_extremum = v + \
                #     0.5 * (deriv[0, 0] * ds + deriv[1, 0] * dr + deriv[2, 0] * dc)
                # print("(s + ds, r + dr, c + dc): ", (s + ds, r + dr, c + dc))
                # break

            # update the coordinates and go on
            s = new_s
            r = new_r
            c = new_c
            i += 1

        # If the exact keypoint is still not found when the loop ends,
        # discard the point:
        if i == niter:
            return None

        # print("(ds, dr, dc): ", (ds, dr, dc))
        # print("(s, r, c): ", (s, r, c))
        # print("(s + ds, r + dr, c + dc): ", (s + ds, r + dr, c + dc))
        return s, r, c, ds, dr, dc, value_of_exact_extremum

    cdef bint _is_low_contrast_or_unstable(self, int s, int r, int c,
                DTYPE_t v, DTYPE_t contrast_threshold=CONTR_THR,
                DTYPE_t stability_threshold=STAB_THR):
        """
        For the experiments in the 'SIFT' paper, all extrema with a value of
        |D(sigma, x, y)| less than 0.03 (which means the extrema are unstable
        with low contrast) were discarded, where D(sigma, x, y) is the Taylor
        expansion (up to the quadratic terms) of the scale-space function.

        """
        cdef:
            DTYPE_t[:, ::1] hessian2 = np.zeros((2, 2), dtype=DTYPE)
            DTYPE_t det

        # print("abs(v): ", abs(v), "contrast_threshold: ", contrast_threshold)
        if abs(v) < contrast_threshold:  # / self.nscas:
            return True

        hessian2[0, 0] = self.diff_scales[s, r + 1, c] + \
                self.diff_scales[s, r - 1, c] - 2 * self.diff_scales[s, r, c]
        hessian2[1, 1] = self.diff_scales[s, r, c + 1] + \
                self.diff_scales[s, r, c - 1] - 2 * self.diff_scales[s, r, c]
        hessian2[0, 1] = (self.diff_scales[s, r + 1, c + 1] +
                self.diff_scales[s, r - 1, c - 1] - self.diff_scales[s, r - 1, c + 1]
                - self.diff_scales[s, r + 1, c - 1]) / 4
        hessian2[1, 0] = hessian2[0, 1]

        det = mt.det(hessian2)

        if det <= 0:
            return True

        if np.trace(hessian2) ** 2 / det \
                < (stability_threshold + 1.0) ** 2 / stability_threshold:
            return False

        return True

    cpdef list find_keypoints_in_octave(self):
        cdef:
            list extrema_points = []
            int si, ri, ci, index = 0, s, r, c
            # Note the symbols ds, dr, dc have different meanings from those in
            # function _find_exact_extremum
            int ds, dr, dc
            DTYPE_t s_offset = 0, r_offset = 0, c_offset = 0, v0, v = 0
            bint is_keypoint = True
            # bint is_maximum = True
            # bint is_minimum = True
            Location loc
            PointFeature point
            # tuple wildcard

        # For each point,
        for si in range(1, self.nscas + 1):
            for ri in range(1, self.nrows - 1):
                for ci in range(1, self.ncols - 1):
                    # we compare it with its 26 neighbors
                    # (here itself included, so 27 comparisons in all)
                    # RESET!!!
                    is_keypoint = True
                    v0 = self.diff_scales[si, ri, ci]
                    if v0 > 0.8 * CONTR_THR:
                        for ds in range(-1, 2):
                            for dr in range(-1, 2):
                                for dc in range(-1, 2):
                                    if self.diff_scales[si, ri, ci] < \
                                       self.diff_scales[si + ds, ri + dr, ci + dc]:
                                        is_keypoint = False
                                        break
                                if not is_keypoint:
                                    break
                            if not is_keypoint:
                                break
                    elif v0 < -0.8 * CONTR_THR:
                        for ds in range(-1, 2):
                            for dr in range(-1, 2):
                                for dc in range(-1, 2):
                                    if self.diff_scales[si, ri, ci] > \
                                       self.diff_scales[si + ds, ri + dr, ci + dc]:
                                        is_keypoint = False
                                        break
                                if not is_keypoint:
                                    break
                            if not is_keypoint:
                                break
                    else:  # v0 == 0
                        is_keypoint = False
                    # -------------------------------------
                    # Use the criterion above.
                    # for ds in range(-1, 2):
                    #     for dr in range(-1, 2):
                    #         for dc in range(-1, 2):
                    #             if self.diff_scales[s, r, c] < \
                    #                self.diff_scales[s + ds, r + dr, c + dc]:
                    #                 is_maximum = False
                    #             if self.diff_scales[s, r, c] > \
                    #                self.diff_scales[s + ds, r + dr, c + dc]:
                    #                 is_minimum = False
                    #             is_keypoint = is_minimum or is_maximum
                    #              # if the point cannot be a key point
                    #             if not is_keypoint:
                    #                 break
                    #         if not is_keypoint:
                    #             break
                    #     if not is_keypoint:
                    #         break
                    # -------------------------------------

                    # if the point IS a key point
                    # (which means is_minimum OR is_maximum is True;
                    # if is_maximum and is_minimum both are True,
                    # then the point must hava SAME value as all its
                    # neighbors, in which case the point is not a key point):

                    # if (self.n_oct, si, ri, ci) == (0, 3, 418, 481):
                    #     print "is keypoint? ", is_keypoint

                    if is_keypoint:  # and (is_maximum != is_minimum):
                        wildcard = self._find_exact_extremum(si, ri, ci)
                        # if (self.n_oct, si, ri, ci) == (0, 3, 418, 481):
                        #     print wildcard

                        # If the exact extremum was not found:
                        if not wildcard:
                            # print "NONE!!!"
                            continue
                        # If found:
                        (s, r, c, s_offset, r_offset, c_offset, v) = wildcard
                        # if abs((r + r_offset) * 2.0 ** self.n_oct - 418.179473877)<0.0001:
                        #     print "!!!!!!!!!!!!!!!!!!!: ", s, r, c
                        if not self._is_low_contrast_or_unstable(s, r, c, v):
                            loc = Location(self.n_oct, s, r, c)
                            p = PointFeature(
                                loc,
                                ((r + r_offset) * 2.0 ** self.n_oct,
                                 (c + c_offset) * 2.0 ** self.n_oct),
                                s + s_offset,
                                self.sigma0 * (2.0 ** (1.0 * s / self.nscas)),
                                self.sigma0 * (2.0 ** (self.n_oct + 1.0 * s / self.nscas))
                                )
                            # TODO: more efficient deduplication?
                            if p not in extrema_points:
                                # print str(p)
                                extrema_points.append(p)

        return extrema_points


@cython.boundscheck(False)
@cython.wraparound(False)
cdef class GaussianPyramid:
    """ The Gaussian pyramid of an input image. """
    # cdef:
    #     list octaves
    #     int nocts

    def __init__(self, DTYPE_t[:, ::1] input, int nocts=-1, int nscas=SCALES,
                 DTYPE_t sigma=SIGMA, bint predesample=False,
                 int predesample_intvl=DSAMP_INTVL):
        """
        :param input: input image (with buffer interface)
            Pixel values are normalize to [0, 1]
        :param nocts: number of octaves
            If given <=0, then nocts will be calculated accroding to:
                nocts = log(min(input.width, input.height)) / log(2) - 2.
            (why not use:
                nocts = int(log(min(input.width, input.height)) / log(2)) + 1
            ?)
        :param nscas: number of scales in each octave - 3
        :param sigma: (default: SIGMA=1.6)
            The 'bottom' image in the 'bottom' octave is blurred from
            The original image `input` by convoluting with G_\{sigma}(x,y).
        :param predesample: (default: False)
            This parameter is to designate whether the input needs to be
            pre-desampled/decimated before the pyramid starts to be constructed.
        :param predesample_intvl: (default: DSAMP_INTVL=2)
            This parameter is to designate the pre-desample interval. It will
            only work when `predesample` is set 'True'.

        """
        cdef:
            GaussianOctave octave
            int o
            DTYPE_t[:, ::1] first

        self.nscas = nscas
        self.sigma = sigma
        self.predesample = predesample
        self.predesample_intvl = predesample_intvl
        self.octaves = []

        if nocts <= 0:
            self.nocts = int(np.log(min(input.shape[0], input.shape[1])) /
                             np.log(2)) - 2
            # print(self.nocts)
        else:
            self.nocts = nocts

        first = np.array(input, dtype=DTYPE)
        if predesample is True:
            first = decimation(first, predesample_intvl)

        # Assume that the input image is blurred from an image at infinite
        # resolution with a Gaussian kernel having sigma=INIT_SIGMA:
        first = gaussian_blur(first,
                              (sigma * sigma - INIT_SIGMA * INIT_SIGMA) ** 0.5)

        for o in range(0, self.nocts):
            octave = GaussianOctave(first, o, nscas, sigma)
            self.octaves.append(octave)
            first = decimation(octave.scales[nscas])
        print("Pyramid initialized. ")
        self.features = self._find_features()

    cdef list _find_keypoints(self):
        """
        return the list of keypoints, which are recorded in the form:
        [[o=0, s0, r0, c0], [o=0, s1, r1, c1],...]

        """
        cdef:
            int o
            list kpts = []
        print("Start finding keypoints...")
        for o in range(0, self.nocts):
            kpts.extend(self.octaves[o].find_keypoints_in_octave())
        print("Finish finding keypoints...")
        return kpts

    cdef list _find_features(self):
        """
        return the list of keypoint features.

        """
        cdef:
            list features
            int i, o, s, r, c
            PointFeature feature

        print("Start finding feature descriptors...")

        # find the keypoints
        features = self._find_keypoints()

        # calculate the keypoints' orientation
        features = calc_keypoints_ori(self, features)

        # calculate the keypoints' feature descriptor vector
        for i in range(0, len(features)):
            feature = features[i]
            o = feature.location.octave
            s = feature.location.scale
            r = feature.location.row
            c = feature.location.col
            feature.descriptor = calc_descriptor(
                self.octaves[o].scales[s], r, c,
                feature.ori,
                feature.sigma_oct)
            # print "print in _find_features: ", np.array(feature.descriptor)

        print("Finish finding feature descriptors...")
        return features

    cpdef save_feature_txt(self, filename, path=OUT_PATH, timestamp=True):
        import os, time

        if not path.endswith(os.sep):
            filename = os.sep.join([path, filename])
        else:
            filename = "".join([path, filename])

        if timestamp:
            timenow = int(time.time())
            time_array = time.localtime(timenow)
            time_str = time.strftime("_%Y%m%d_%H%M%S")
            filename += time_str

        filename = os.extsep.join([filename, "txt"])

        if os.path.exists(filename):
            print("File '{0}' exists. Writing cancelled.".format(filename))
            return

        if os.path.exists(path) == False:
            os.makedirs(path)
            print("Path '{0}' doesn't exist. Create it.".format(path))

        f = open(filename, "w")
        f.write("row_coord" + "\t" + "col_coord" + "\t" + "scale" +
                "\t" + "orientation" + "\t" + "descriptor" + "\n")
        for feature in self.features:
            f.write(str(feature.coord[0]) + "\t" +
                    str(feature.coord[1]) + "\t" +
                    str(feature.sigma_abs) + "\t" +
                    str(feature.ori) + "\t" +
                    str(np.array(feature.descriptor)) + "\n")
        f.close()
        print("Features saved in '{0}'.".format(filename))