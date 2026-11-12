pub fn answer() -> i32 {
    1
}

#[cfg(test)]
mod tests {
    #[test]
    fn answer_is_one() {
        assert_eq!(super::answer(), 1);
    }
}
