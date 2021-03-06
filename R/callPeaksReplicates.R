#' Fit a multivariate Hidden Markov Model to multiple ChIP-seq replicates
#'
#' Fit an HMM to multiple ChIP-seq replicates and derive correlation measures. Input is a list of \code{\link{uniHMM}}s generated by \code{\link{callPeaksUnivariate}}.
#'
#' @author Aaron Taudt
#' @param hmm.list A list of \code{\link{uniHMM}}s generated by \code{\link{callPeaksUnivariate}}, e.g. \code{list(hmm1,hmm2,...)} or \code{c("file1","file2",...)}. Alternatively, this parameter also accepts a \code{\link{multiHMM}} and will check if the distance between replicates is greater than \code{max.distance}.
#' @param max.states The maximum number of combinatorial states to consider. The default (32) is sufficient to treat up to 5 replicates exactly and more than 5 replicates approximately.
#' @param force.equal The default (\code{FALSE}) allows replicates to differ in their peak-calls, although the majority will usually be identical. If \code{force.equal=TRUE}, all peaks will be identical among all replicates.
#' @param eps Convergence threshold for the Baum-Welch algorithm.
#' @param max.iter The maximum number of iterations for the Baum-Welch algorithm. The default \code{NULL} is no limit.
#' @param max.time The maximum running time in seconds for the Baum-Welch algorithm. If this time is reached, the Baum-Welch will terminate after the current iteration finishes. The default \code{NULL} is no limit.
#' @param keep.posteriors If set to \code{TRUE}, posteriors will be available in the output. This is useful to change the post.cutoff later, but increases the necessary disk space to store the result immense.
#' @param num.threads Number of threads to use. Setting this to >1 may give increased performance.
#' @param max.distance This number is used as a cutoff to group replicates based on their distance matrix. The lower this number, the more similar replicates have to be to be grouped together.
#' @param per.chrom If \code{per.chrom=TRUE} chromosomes will be treated separately. This tremendously speeds up the calculation but results might be noisier as compared to \code{per.chrom=FALSE}, where all chromosomes are concatenated for the HMM.
#' @return Output is a \code{\link{multiHMM}} object with additional entry \code{replicateInfo}. If only one \code{\link{uniHMM}} was given as input, a simple list() with the \code{replicateInfo} is returned.
#' @seealso \code{\link{multiHMM}}, \code{\link{callPeaksUnivariate}}, \code{\link{callPeaksMultivariate}}
#' @importFrom stats hclust cutree dist
#' @export
#' @examples 
#'# Let's get some example data with 3 replicates
#'file.path <- system.file("extdata","euratrans", package='chromstaRData')
#'files <- list.files(file.path, pattern="H3K27me3.*SHR.*bam$", full.names=TRUE)[1:3]
#'# Obtain chromosome lengths. This is only necessary for BED files. BAM files are
#'# handled automatically.
#'data(rn4_chrominfo)
#'# Define experiment structure
#'exp <- data.frame(file=files, mark='H3K27me3', condition='SHR', replicate=1:3,
#'                  pairedEndReads=FALSE, controlFiles=NA)
#'# We use bin size 1000bp and chromosome 12 to keep the example quick
#'binned.data <- list()
#'for (file in files) {
#'  binned.data[[basename(file)]] <- binReads(file, binsizes=1000, stepsizes=500,
#'                                            experiment.table=exp,
#'                                            assembly=rn4_chrominfo, chromosomes='chr12')
#'}
#'# The univariate fit is obtained for each replicate
#'models <- list()
#'for (i1 in 1:length(binned.data)) {
#'  models[[i1]] <- callPeaksUnivariate(binned.data[[i1]], max.time=60, eps=1)
#'}
#'# Obtain peak calls considering information from all replicates
#'multi.model <- callPeaksReplicates(models, force.equal=TRUE, max.time=60, eps=1)
#'
callPeaksReplicates <- function(hmm.list, max.states=32, force.equal=FALSE, eps=0.01, max.iter=NULL, max.time=NULL, keep.posteriors=TRUE, num.threads=1, max.distance=0.2, per.chrom=TRUE) {

    ## Enable reanalysis of multivariate HMM
    if (class(hmm.list)==class.multivariate.hmm) {

        multimodel <- hmm.list
        if (is.null(multimodel$replicateInfo)) {
            warning("No check done because no replicateInfo was found")
            return(multimodel)
        }
        info.df <- multimodel$replicateInfo$info
        cor.matrix <- multimodel$replicateInfo$correlation
        dist.matrix <- multimodel$replicateInfo$distance
        hc <- stats::hclust(dist.matrix)
        info.df$group <- stats::cutree(hc, h=max.distance)

    ### Call peaks for several replicates ###
    } else {

        hmms <- loadHmmsFromFiles(hmm.list, check.class=class.univariate.hmm)

        ## Univariate replicateInfo
        ids <- sapply(hmms, function(x) { x$info$ID })
        weight.univariate <- sapply(hmms, function(x) { x$weights['modified'] })
        total.count <- sapply(hmms, function(x) { sum(x$bins$counts) })
        info.df <- data.frame(total.count=total.count, weight.univariate=weight.univariate)
        if (!is.null(unlist(ids))) {
            rownames(info.df) <- ids
        }

        ### Correlation analysis ###
        if (length(hmms) == 1) {
            info.df$weight.multivariate <- NA
            info.df$group <- 1
            cor.matrix <- NA
            dist.matrix <- NA
            multimodel <- list()
        } else if (length(hmms) >= 2) {
            max.states <- min(max.states, 2^length(hmms))
            if (force.equal) {
                states2use <- state.brewer(rep(paste0('r.',paste(ids, collapse='-')),length(hmms)))
                multimodel <- callPeaksMultivariate(hmms, use.states=states2use, eps=eps, max.iter=max.iter, max.time=max.time, keep.posteriors=keep.posteriors, num.threads=num.threads, per.chrom=per.chrom)
            } else {
                states2use <- state.brewer(paste0('x.', ids))
                multimodel <- callPeaksMultivariate(hmms, use.states=states2use, max.states=max.states, eps=eps, max.iter=max.iter, max.time=max.time, keep.posteriors=keep.posteriors, num.threads=num.threads, per.chrom=per.chrom)
            }
            binstates <- dec2bin(multimodel$bins$state, colnames=multimodel$info$ID)
            cor.matrix <- cor(binstates)
            weight.multivariate <- apply(binstates, 2, sum) / nrow(binstates)
            info.df$weight.multivariate <- weight.multivariate
            dist.matrix <- stats::dist(cor.matrix)
            hc <- stats::hclust(dist.matrix)
            info.df$group <- stats::cutree(hc, h=max.distance)
        }

        ## Make return object
        multimodel$replicateInfo$info <- info.df
        multimodel$replicateInfo$correlation <- cor.matrix
        multimodel$replicateInfo$distance <- dist.matrix

    }

    ## Check groups and issue warnings
    num.groups <- length(unique(info.df$group))
    if (num.groups > 1) {
        avg.total.count <- unlist(lapply(split(info.df, info.df$group), function(x) { mean(x$total.count) }))
        IDs.keep <- rownames(info.df)[info.df$group==names(avg.total.count[which.max(avg.total.count)])]
        IDs.keep.string <- paste(IDs.keep, collapse='\n')
        IDs.throw <- rownames(info.df)[info.df$group!=names(avg.total.count[which.max(avg.total.count)])]
        IDs.throw.string <- paste(IDs.throw, collapse='\n')
        string <- paste0("Your replicates cluster in ", num.groups, " groups. Consider redoing your analysis with only the group with the highest average coverage:\n", IDs.keep.string, "\nReplicates from groups with lower coverage are:\n", IDs.throw.string)
        warning(string)
    }

    return(multimodel)

}
